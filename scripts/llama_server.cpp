#include "llama.h"

#include "llama_server_text.h"

#include <algorithm>
#include <chrono>
#include <cctype>
#include <cmath>
#include <functional>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <memory>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

class LlamaEngine {
public:
    llama_model *model = nullptr;
    llama_context *ctx = nullptr;
    const llama_vocab *vocab = nullptr;
    int n_ctx = 1536;
    int pos = 0;
    std::vector<llama_token> last_prompt_tokens;
    std::vector<llama_logit_bias> special_biases;
    // Personal-lexicon bias: a mild positive nudge on the first token of words the
    // user actually types often, so completions lean toward their vocabulary.
    std::vector<llama_logit_bias> lexicon_biases;
    std::string lexicon_key;
    // Mean model probability of the sampled tokens for the LAST generate() call —
    // the confidence signal the UI uses to suppress low-quality suggestions.
    double last_avg_prob = 0.0;

    explicit LlamaEngine(const std::string &path) {
        llama_backend_init();
        llama_log_set([](enum ggml_log_level, const char *, void *) {}, nullptr);

        auto mp = llama_model_default_params();
        mp.n_gpu_layers = 999;
        mp.use_mmap = true;
        mp.use_mlock = false;
        model = llama_model_load_from_file(path.c_str(), mp);
        if (!model) throw std::runtime_error("failed to load model: " + path);

        auto cp = llama_context_default_params();
        cp.n_ctx = n_ctx;
        cp.n_batch = 512;
        cp.n_ubatch = 512;
        cp.n_threads = std::max(2u, std::thread::hardware_concurrency() / 2);
        cp.n_threads_batch = std::max(2u, std::thread::hardware_concurrency() / 2);
        cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO;
        cp.swa_full = false;
        cp.no_perf = true;
        ctx = llama_init_from_model(model, cp);
        if (!ctx) throw std::runtime_error("failed to create llama context");
        vocab = llama_model_get_vocab(model);
        init_biases();
    }

    ~LlamaEngine() {
        if (ctx) llama_free(ctx);
        if (model) llama_model_free(model);
        llama_backend_free();
    }

    std::vector<llama_token> tokenize(const std::string &text, bool add_special) {
        int n = llama_tokenize(vocab, text.c_str(), (int)text.size(), nullptr, 0, add_special, true);
        if (n < 0) n = -n;
        std::vector<llama_token> toks(n);
        int got = llama_tokenize(vocab, text.c_str(), (int)text.size(), toks.data(), (int)toks.size(), add_special, true);
        if (got < 0) throw std::runtime_error("tokenize failed");
        toks.resize(got);
        return toks;
    }

    std::string detok(llama_token tok) {
        char buf[256];
        int n = llama_token_to_piece(vocab, tok, buf, sizeof(buf), 0, false);
        if (n < 0) return "";
        return std::string(buf, buf + n);
    }

    // FIM (fill-in-the-middle) support, spec §E#13. A mid-line completion has real
    // text AFTER the caret; a plain continuation model can't see it and tends to
    // duplicate or ignore it. When the loaded GGUF carries the infill special tokens
    // (Qwen2.5-Coder, CodeLlama, DeepSeek-Coder, StarCoder2, …) we frame the request as
    // <pre>prefix<suf>suffix<mid> so the model fills the gap between what's typed and
    // what trails the caret. Models without these tokens fall back to plain
    // continuation in the request handler.
    bool fim_available() const {
        return llama_vocab_fim_pre(vocab) != LLAMA_TOKEN_NULL &&
               llama_vocab_fim_suf(vocab) != LLAMA_TOKEN_NULL &&
               llama_vocab_fim_mid(vocab) != LLAMA_TOKEN_NULL;
    }

    // Assemble the FIM token sequence. llama.cpp's reference infill ordering is
    // [FIM_PRE] prefix [FIM_SUF] suffix [FIM_MID]; the model generates the middle after
    // FIM_MID. prefix/suffix are tokenized WITHOUT special parsing so caret-adjacent
    // user text ("<", "|", …) can never be mistaken for control tokens.
    std::vector<llama_token> build_fim_tokens(const std::string &prefix, const std::string &suffix) {
        std::vector<llama_token> toks;
        auto pre = tokenize(prefix, false);
        auto suf = tokenize(suffix, false);
        // Bound each side so the FIM frame still fits the context with generation room.
        int side_cap = (n_ctx - 64) / 2;
        if (side_cap < 1) side_cap = 1;
        if ((int)pre.size() > side_cap) pre.erase(pre.begin(), pre.end() - side_cap);  // keep tail nearest caret
        if ((int)suf.size() > side_cap) suf.resize(side_cap);                          // keep head nearest caret
        toks.push_back(llama_vocab_fim_pre(vocab));
        toks.insert(toks.end(), pre.begin(), pre.end());
        toks.push_back(llama_vocab_fim_suf(vocab));
        toks.insert(toks.end(), suf.begin(), suf.end());
        toks.push_back(llama_vocab_fim_mid(vocab));
        return toks;
    }

    void init_biases() {
        // Ban every control / special / added token by id, read from the actual vocab, so
        // the model can't emit BOS/EOS/turn/chat/repo markup into a plaintext completion.
        // Model-agnostic: covers Gemma's <bos>/<eos>/<start_of_turn>… and SmolLM2's
        // <|endoftext|>/<|im_start|>/<reponame>… alike. The old approach tokenized literal
        // Gemma strings ("<|", "|>", …) with parse_special — correct for Gemma, but in a
        // byte-level-BPE vocab (Qwen/SmolLM2) "<|" is NOT one special token; it splits into
        // the ordinary "<" and "|" byte-pairs, so banning them would stop the model from
        // ever emitting those characters (fatal for code). Banning by attribute never
        // touches a normal text token.
        int n = llama_vocab_n_tokens(vocab);
        for (llama_token id = 0; id < n; ++id) {
            auto attr = llama_vocab_get_attr(vocab, id);
            if (attr & (LLAMA_TOKEN_ATTR_CONTROL | LLAMA_TOKEN_ATTR_USER_DEFINED |
                        LLAMA_TOKEN_ATTR_UNKNOWN | LLAMA_TOKEN_ATTR_UNUSED)) {
                special_biases.push_back({id, -INFINITY});
            }
        }
    }

    // `words` is a space-separated list of the user's distinctive vocabulary,
    // most-frequent first. Each word's first token (with a leading space, i.e. as a
    // word start) gets a small logit boost. +0.5 is deliberately gentle: enough to
    // break ties toward the user's own words, far too small to force one in where
    // it doesn't fit (min-p and the nucleus still apply afterwards).
    void set_lexicon(const std::string &words, float weight) {
        // The cache key folds in the weight so moving the personalization slider rebuilds the
        // bias table even when the word list is unchanged.
        std::string key = words + "\x1f" + std::to_string(weight);
        if (key == lexicon_key) return;
        lexicon_key = key;
        lexicon_biases.clear();
        if (words.empty() || weight <= 0.0f) return;
        std::set<llama_token> banned;
        for (const auto &b : special_biases) banned.insert(b.token);
        std::set<llama_token> seen;
        std::istringstream iss(words);
        std::string w;
        while (iss >> w && lexicon_biases.size() < 64) {
            auto toks = tokenize(" " + w, false);
            if (toks.empty()) continue;
            llama_token t = toks[0];
            if (banned.count(t) || !seen.insert(t).second) continue;
            lexicon_biases.push_back({t, weight});   // strength-scaled by the app (0.5 baseline)
        }
    }

    llama_sampler * make_sampler(const std::vector<llama_token> &prompt_tokens) {
        auto params = llama_sampler_chain_default_params();
        params.no_perf = true;
        llama_sampler * chain = llama_sampler_chain_init(params);
        if (!special_biases.empty()) {
            llama_sampler_chain_add(chain, llama_sampler_init_logit_bias(llama_vocab_n_tokens(vocab), (int32_t)special_biases.size(), special_biases.data()));
        }
        if (!lexicon_biases.empty()) {
            llama_sampler_chain_add(chain, llama_sampler_init_logit_bias(llama_vocab_n_tokens(vocab), (int32_t)lexicon_biases.size(), lexicon_biases.data()));
        }
        // Inline autocomplete wants the single highest-probability continuation, not a
        // creative tangent. A mild repetition penalty (anti-loop) then GREEDY (argmax):
        // eval_compare.py showed the greedy/raw path beats the old tuned nucleus
        // (temp 0.16 / top-p / min-p) on real typed content — the stochastic sampler was
        // costing accuracy and type-through length, clamping a better-distilled model back
        // to the weaker model's ceiling. TYPER_SAMPLER=nucleus restores the old sampler.
        llama_sampler_chain_add(chain, llama_sampler_init_penalties(96, 1.04f, 0.0f, 0.0f));
        const char *mode = std::getenv("TYPER_SAMPLER");
        if (mode && std::string(mode) == "nucleus") {
            llama_sampler_chain_add(chain, llama_sampler_init_top_k(32));
            llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.88f, 1));
            llama_sampler_chain_add(chain, llama_sampler_init_min_p(0.04f, 1));
            llama_sampler_chain_add(chain, llama_sampler_init_temp(0.16f));
            llama_sampler_chain_add(chain, llama_sampler_init_dist(0xC07A));
        } else {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy());
        }
        // Only the penalties sampler is stateful, with penalty_last_n = 96, so only the
        // last 96 prompt tokens can affect sampling. Replaying the whole prompt through
        // accept() every request is wasted work.
        size_t start = prompt_tokens.size() > 96 ? prompt_tokens.size() - 96 : 0;
        for (size_t i = start; i < prompt_tokens.size(); ++i) llama_sampler_accept(chain, prompt_tokens[i]);
        return chain;
    }

    void decode_tokens(const std::vector<llama_token> &tokens, int token_start, int token_end, int pos_start, bool logits_last) {
        const int chunk = 512;
        for (int off = token_start; off < token_end; off += chunk) {
            int n = std::min(chunk, token_end - off);
            std::vector<llama_pos> positions(n);
            std::vector<int32_t> n_seq_id(n, 1);
            std::vector<llama_seq_id> seq_values(n, 0);
            std::vector<llama_seq_id *> seq_ptrs(n);
            std::vector<int8_t> logits(n, 0);
            for (int i = 0; i < n; ++i) {
                positions[i] = pos_start + (off - token_start) + i;
                seq_ptrs[i] = &seq_values[i];
            }
            if (logits_last && off + n == token_end) logits[n - 1] = 1;
            llama_batch batch{};
            batch.n_tokens = n;
            batch.token = const_cast<llama_token *>(tokens.data() + off);
            batch.embd = nullptr;
            batch.pos = positions.data();
            batch.n_seq_id = n_seq_id.data();
            batch.seq_id = seq_ptrs.data();
            batch.logits = logits.data();
            if (llama_decode(ctx, batch) != 0) throw std::runtime_error("llama_decode failed");
        }
    }

    // Allocation-free decode of one generated token (the per-token hot loop): the
    // general decode_tokens builds six heap vectors per call, all of which collapse
    // to single stack values for a batch of one.
    void decode_one(llama_token tok) {
        llama_pos p = pos;
        int32_t n_seq = 1;
        llama_seq_id seq = 0;
        llama_seq_id *seq_ptr = &seq;
        int8_t want_logits = 1;
        llama_batch batch{};
        batch.n_tokens = 1;
        batch.token = &tok;
        batch.embd = nullptr;
        batch.pos = &p;
        batch.n_seq_id = &n_seq;
        batch.seq_id = &seq_ptr;
        batch.logits = &want_logits;
        if (llama_decode(ctx, batch) != 0) throw std::runtime_error("llama_decode failed");
        pos++;
    }

    void prepare_prompt(const std::vector<llama_token> &toks) {
        int common = 0;
        int max_common = std::min(last_prompt_tokens.size(), toks.size());
        while (common < max_common && last_prompt_tokens[common] == toks[common]) common++;

        // Re-decode the last prompt token so logits always correspond to this prompt,
        // while keeping as much reusable KV prefix as possible.
        if (!last_prompt_tokens.empty() && common > 0 && !toks.empty()) common = std::min<int>(common, (int)toks.size() - 1);

        // Rank-1 TTFT lever instrumentation: how many leading tokens we reuse from the
        // previous prompt's KV vs how many we re-decode. The bench harness scrapes this
        // exact format; gated by env so production stderr stays quiet (off by default).
        if (std::getenv("TYPER_REUSE_LOG"))
            fprintf(stderr, "REUSE common=%d len=%zu\n", common, (size_t)toks.size());

        if (common <= 0) {
            llama_memory_clear(llama_get_memory(ctx), true);
            pos = 0;
        } else {
            llama_memory_seq_rm(llama_get_memory(ctx), 0, common, -1);
            pos = common;
        }
        if (pos < (int)toks.size()) {
            decode_tokens(toks, pos, (int)toks.size(), pos, true);
            pos = (int)toks.size();
        }
        last_prompt_tokens = toks;
    }

    // Probability the model assigned to `id` in the CURRENT (raw, pre-sampler)
    // logits. Two passes over the vocab (~0.3ms) per generated token; the price of
    // an honest confidence signal instead of a proxy.
    double token_prob(llama_token id) {
        const float *lg = llama_get_logits_ith(ctx, -1);
        if (!lg) return 0.0;
        const int nv = llama_vocab_n_tokens(vocab);
        float mx = lg[0];
        for (int j = 1; j < nv; ++j) if (lg[j] > mx) mx = lg[j];
        double denom = 0.0;
        for (int j = 0; j < nv; ++j) denom += std::exp((double)(lg[j] - mx));
        return std::exp((double)(lg[id] - mx)) / denom;
    }

    // on_token(full_output_so_far, mean_prob_so_far) is called after each token;
    // returning false stops generation early (used for streaming + early mid-word
    // suppression). The final mean probability lands in last_avg_prob.
    std::string generate(const std::string &prompt, int max_tokens,
                         const std::function<bool(const std::string &, double)> &on_token = nullptr) {
        // add_special lets llama.cpp prepend the model's own BOS only when its vocab
        // declares one (Gemma yes; Qwen3/SmolLM2 base no) — replaces the old hardcoded
        // "<bos>" literal so any base model tokenizes correctly.
        auto toks = tokenize(prompt, llama_vocab_get_add_bos(vocab));
        return generate_from_tokens(toks, max_tokens, on_token);
    }

    // The decode + sampling loop, sharing one implementation between plain-continuation
    // generate() and the FIM path (which pre-builds its own <pre>/<suf>/<mid> token
    // sequence). `toks` is the already-tokenized prompt.
    std::string generate_from_tokens(std::vector<llama_token> toks, int max_tokens,
                         const std::function<bool(const std::string &, double)> &on_token = nullptr) {
        int over = (int)toks.size() + max_tokens + 8 - n_ctx;
        if (over > 0) {
            // Front-truncate to fit the context window. Clamp so at least one token
            // remains, and invalidate the KV prefix cache: after a front shift the
            // cached cells map to different source tokens, so reusing them by value
            // match would splice semantically stale content into the prompt.
            int drop = std::min(over, (int)toks.size() - 1);
            if (drop > 0) toks.erase(toks.begin(), toks.begin() + drop);
            last_prompt_tokens.clear();
        }
        prepare_prompt(toks);

        // RAII so a throw from decode_tokens (or on_token) can't leak the sampler.
        std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> smpl(make_sampler(toks), &llama_sampler_free);
        std::string out;
        double prob_sum = 0.0;
        int prob_n = 0;
        last_avg_prob = 0.0;
        for (int i = 0; i < max_tokens; ++i) {
            llama_token id = llama_sampler_sample(smpl.get(), ctx, -1);
            // The raw logits for this step are still in the context (the sampler
            // works on a copy), so the model's true probability of the chosen
            // token is available before we decode it.
            prob_sum += token_prob(id);
            prob_n++;
            last_avg_prob = prob_sum / prob_n;
            llama_sampler_accept(smpl.get(), id);
            if (llama_vocab_is_eog(vocab, id)) break;
            out += detok(id);
            decode_one(id);
            if (on_token && !on_token(out, last_avg_prob)) break;
        }
        return out;
    }

    // Raw, harness-free decode: the SAME llama.cpp backend and BOS handling as generate(),
    // but greedy (argmax) with none of TYPER's value-add — no tuned nucleus sampler, no
    // lexicon bias, no streaming word-shaping/echo-removal/word-limit/quality gate. Used by
    // eval_compare.py as the "raw model" baseline, so the harness-vs-raw delta isolates how
    // much the harness itself helps (or hurts). Control/special tokens are still banned (that
    // is table-stakes for any sane integration, not harness cleverness).
    std::string generate_raw(const std::string &prompt, int max_tokens) {
        auto toks = tokenize(prompt, llama_vocab_get_add_bos(vocab));
        int over = (int)toks.size() + max_tokens + 8 - n_ctx;
        if (over > 0) {
            int drop = std::min(over, (int)toks.size() - 1);
            if (drop > 0) toks.erase(toks.begin(), toks.begin() + drop);
            last_prompt_tokens.clear();
        }
        prepare_prompt(toks);

        auto params = llama_sampler_chain_default_params();
        params.no_perf = true;
        llama_sampler *chain = llama_sampler_chain_init(params);
        if (!special_biases.empty()) {
            llama_sampler_chain_add(chain, llama_sampler_init_logit_bias(llama_vocab_n_tokens(vocab), (int32_t)special_biases.size(), special_biases.data()));
        }
        llama_sampler_chain_add(chain, llama_sampler_init_greedy());
        std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> smpl(chain, &llama_sampler_free);

        std::string out;
        double prob_sum = 0.0;
        int prob_n = 0;
        last_avg_prob = 0.0;
        for (int i = 0; i < max_tokens; ++i) {
            llama_token id = llama_sampler_sample(smpl.get(), ctx, -1);
            prob_sum += token_prob(id);
            prob_n++;
            last_avg_prob = prob_sum / prob_n;
            llama_sampler_accept(smpl.get(), id);
            if (llama_vocab_is_eog(vocab, id)) break;
            out += detok(id);
            decode_one(id);
        }
        return out;
    }
};

static std::string prompt_complete(const std::string &context) {
    // The prompt is the plain context. The model's real BOS (if it uses one) is prepended
    // at tokenize time via add_special — see generate(), which tokenizes with add_special
    // = llama_vocab_get_add_bos(vocab). Models trained with a leading BOS (Gemma) get it;
    // models without one (Qwen3/SmolLM2 base) get nothing. The old hardcoded literal
    // "<bos>" was correct only for Gemma and tokenizes to junk bytes in other vocabularies,
    // producing the degenerate, repetitive output a missing/wrong BOS causes.
    return context;
}

int main(int argc, char **argv) {
    std::string model_path;
    bool check = false;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if ((a == "--model" || a == "--model-path") && i + 1 < argc) model_path = argv[++i];
        else if (a == "--check") check = true;
    }
    if (model_path.empty()) {
        const char *home = std::getenv("HOME");
        model_path = std::string(home ? home : ".") + "/Library/Application Support/typer/Models/gemma-4-E2B-i1-Q4_K_M.gguf";
    }

    try {
        LlamaEngine engine(model_path);
        if (check) {
            const char *tmpl = llama_model_chat_template(engine.model, nullptr);
            std::cerr << "chat_template=" << (tmpl ? tmpl : "(null)") << std::endl;
            auto t0 = std::chrono::steady_clock::now();
            std::string out = first_line_clean(engine.generate(prompt_complete("I was walking to the store when I realized"), 14));
            auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count();
            std::cerr << "loaded; sample=" << out << " latency_ms=" << ms << std::endl;
            return 0;
        }

        std::string line;
        while (std::getline(std::cin, line)) {
            try {
                // strip_disallowed is the second line of defence behind the JSON
                // unescaper: control / private-use / U+FFFD scalars and invalid UTF-8
                // never carry meaning, and one of them in the context is enough to make
                // a greedy decoder loop on it forever. Whatever the transport does, the
                // prompt only ever sees text.
                std::string context = strip_disallowed(json_get_string(line, "context"));
                // Text AFTER the caret (spec §E#13). Present only for mid-line completions;
                // empty for end-of-line, where the plain continuation path is used as before.
                std::string suffix = strip_disallowed(json_get_string(line, "suffix"));
                int max_words = std::max(1, std::min(32, json_get_int(line, "max_words", 7)));

                // Tokenize helper (W1B / spec C.4): count tokens for an arbitrary block so
                // the Swift side can budget the prompt in token space instead of by char
                // count. Pure measurement — it never touches the KV cache, the sampler, or
                // FIM, so it is safe to interleave with completion requests on the same
                // process. `add_bos` mirrors the per-model BOS handling generate() uses.
                // Returns {"ok":true,"n_tokens":N}; the full id list is omitted (the Swift
                // budgeter only needs the count, and shipping thousands of ids per call is
                // wasteful) but a {"tokens":[...]} array is included when "ids":1 is set.
                if (json_get_string(line, "mode") == "tokenize") {
                    bool add_bos = json_get_int(line, "add_bos", 1) != 0 &&
                                   llama_vocab_get_add_bos(engine.vocab);
                    auto toks = engine.tokenize(context, add_bos);
                    std::string out = "{\"ok\":true,\"n_tokens\":" + std::to_string(toks.size());
                    if (json_get_int(line, "ids", 0) != 0) {
                        out += ",\"tokens\":[";
                        for (size_t i = 0; i < toks.size(); ++i) {
                            if (i) out += ',';
                            out += std::to_string((int)toks[i]);
                        }
                        out += "]";
                    }
                    out += "}";
                    std::cout << out << "\n" << std::flush;
                    continue;
                }

                // Both truncations cut on a byte offset and can split a multi-byte
                // character, so re-strip afterwards to drop the orphaned bytes.
                if (context.size() > 2200) context = strip_disallowed(stable_tail(context, 2200));
                // Bound the FIM suffix: the trailing text only needs to be enough to
                // condition the gap (the model fills BETWEEN prefix and suffix), and a
                // huge trailing document would crowd the context. Keep the head (nearest
                // the caret) since that is what the completion must agree with.
                if (suffix.size() > 600) { suffix.resize(600); suffix = strip_disallowed(suffix); }

                // Raw baseline path (eval_compare.py): greedy decode, harness logic stripped,
                // only first-line + trim cleanup so the comparison reflects the model itself.
                if (json_get_string(line, "mode") == "raw") {
                    int raw_tokens = std::max(8, std::min(28, max_words + 12));
                    std::string raw = engine.generate_raw(prompt_complete(context), raw_tokens);
                    size_t nl = raw.find('\n'); if (nl != std::string::npos) raw.resize(nl);
                    std::string out = trim(raw);
                    char cbuf[16]; snprintf(cbuf, sizeof(cbuf), "%.3f", engine.last_avg_prob);
                    if (out.empty()) std::cout << "{\"ok\":true,\"suggestion\":null}\n" << std::flush;
                    else std::cout << "{\"ok\":true,\"suggestion\":{\"kind\":\"completion\",\"text\":\""
                                   << json_escape(out) << "\",\"conf\":" << cbuf << "}}\n" << std::flush;
                    continue;
                }
                engine.set_lexicon(strip_disallowed(json_get_string(line, "lexicon")),
                                   (float)json_get_double(line, "lexicon_bias", 0.5));

                int max_tokens = std::max(8, std::min(18, max_words + 7));
                bool ctx_ends_space = context.empty() || std::isspace((unsigned char)context.back());
                bool ctx_ends_alnum = !context.empty() && std::isalnum((unsigned char)context.back());

                // The model signals a word boundary itself: a leading-space token
                // ("jumps" -> " jumps") means "new word"; no leading space ("etion"
                // after "autocompl", "!") means "continue this word / punctuation".
                bool first_seen = false, lead_space = false, suppressed = false;
                std::string last_emitted;

                // `cleaned` is first_line_clean(full), computed once by the caller.
                // remove_echo is O(context) per call, so run it only for the FINAL
                // result (dropEcho=true), never for every streamed partial.
                auto shape = [&](const std::string &cleaned, bool dropEcho) -> std::string {
                    std::string s = dropEcho ? remove_echo(cleaned, context) : cleaned;
                    size_t nl = s.find('\n'); if (nl != std::string::npos) s.resize(nl);
                    s = limit_words(s, max_words);
                    if (!s.empty() && !ctx_ends_space && lead_space) s = " " + s;
                    return s;
                };

                // Mid-line FIM (spec §E#13): when there is trailing text after the caret
                // AND the model exposes infill tokens, frame the request as
                // <pre>context<suf>suffix<mid> so the completion fits the gap instead of
                // duplicating or ignoring what follows. Otherwise fall back to plain
                // continuation (the Swift side only sends `suffix` when mid-line
                // completion is enabled, so non-FIM models simply behave as before).
                bool use_fim = !trim(suffix).empty() && engine.fim_available();
                std::vector<llama_token> fim_toks;
                if (use_fim) fim_toks = engine.build_fim_tokens(context, suffix);

                // Stream partial completions token-by-token so the UI shows the
                // first word almost immediately instead of waiting for all of them.
                auto on_stream =
                    [&](const std::string &full, double conf) -> bool {
                        std::string s = first_line_clean(full);
                        if (s.empty()) return true;
                        if (!first_seen) {
                            first_seen = true;
                            lead_space = std::isspace((unsigned char)full[0]) != 0;
                            // Early mid-word suppression: stop before flashing a
                            // wrong subword continuation.
                            if (ctx_ends_alnum && !lead_space && std::isalnum((unsigned char)s[0])) {
                                suppressed = true; return false;
                            }
                        }
                        // strip_format_scalars, not a rejection: an invisible (a BOM, a
                        // zero-width space, a bidi mark) dragged in from the context is
                        // not the model misbehaving, and the Swift side refuses text that
                        // carries one — so clean it out and keep the completion.
                        std::string shaped = strip_format_scalars(utf8_safe(shape(s, false)));
                        // Output gate, mid-stream: a control / private-use / U+FFFD scalar
                        // (or invalid UTF-8 that utf8_safe's incomplete-tail trim did not
                        // explain) means the model is emitting garbage, not prose. Stop now
                        // so it never flashes in the ghost text; `suppressed` makes the
                        // final answer "no completion".
                        if (has_disallowed_scalar(shaped)) { suppressed = true; return false; }
                        // A leading percentage ("100%") is unambiguous even mid-stream and
                        // is the classic OCR-chrome leak — kill it before it flashes. Bare
                        // numbers wait for the final gate (mid-stream "100" may yet become
                        // "100 dollars").
                        {
                            std::string ts = trim(shaped);
                            size_t k = 0;
                            if (!ts.empty() && ts[k] == '$') k++;
                            size_t kd = k;
                            while (k < ts.size() && (std::isdigit((unsigned char)ts[k]) || ts[k] == '.' || ts[k] == ',')) k++;
                            if (k > kd && k < ts.size() && ts[k] == '%' && !std::isdigit((unsigned char)last_nonspace(context))) {
                                suppressed = true;
                                return false;
                            }
                        }
                        if (!shaped.empty() && shaped != last_emitted) {
                            last_emitted = shaped;
                            char cbuf[16];
                            snprintf(cbuf, sizeof(cbuf), "%.3f", conf);
                            std::cout << "{\"p\":\"" << json_escape(shaped) << "\",\"conf\":" << cbuf << "}\n" << std::flush;
                        }
                        int wc = 0; bool inw = false;
                        for (char c : shaped) { if (std::isspace((unsigned char)c)) { if (inw) wc++; inw = false; } else inw = true; }
                        if (inw) wc++;
                        // Stop at enough words, or at a natural sentence end.
                        char last = shaped.empty() ? 0 : shaped.back();
                        if (wc >= 3 && (last == '.' || last == '!' || last == '?')) return false;
                        return wc < max_words;
                    };

                std::string raw = use_fim
                    ? engine.generate_from_tokens(fim_toks, max_tokens, on_stream)
                    : engine.generate(prompt_complete(context), max_tokens, on_stream);

                std::string out;
                if (!suppressed) {
                    // utf8_safe first: the token budget can end mid-character, and that
                    // truncated tail is not the model misbehaving — trim it rather than
                    // let looks_bad_completion's invalid-UTF-8 gate throw the whole
                    // (otherwise good) completion away.
                    out = strip_format_scalars(utf8_safe(shape(first_line_clean(raw), true)));
                    if (looks_bad_completion(out) || is_orphan_number(out, context)) out.clear();
                }
                if (out.empty()) {
                    std::cout << "{\"ok\":true,\"suggestion\":null}\n" << std::flush;
                } else {
                    char cbuf[16];
                    snprintf(cbuf, sizeof(cbuf), "%.3f", engine.last_avg_prob);
                    std::cout << "{\"ok\":true,\"suggestion\":{\"kind\":\"completion\",\"text\":\"" << json_escape(out)
                              << "\",\"conf\":" << cbuf << "}}\n" << std::flush;
                }
            } catch (const std::exception &e) {
                std::cout << "{\"ok\":false,\"error\":\"" << json_escape(e.what()) << "\",\"suggestion\":null}\n" << std::flush;
            }
        }
    } catch (const std::exception &e) {
        std::cerr << "fatal: " << e.what() << std::endl;
        return 1;
    }
    return 0;
}
