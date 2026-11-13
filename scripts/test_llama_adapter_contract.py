#!/usr/bin/env python3
"""Host-side contract test for the NEXUS llama.cpp C ABI adapter.

A fake llama API exercises the native adapter's load/generate/cancel/unload
contract without claiming that real llama.cpp or Android NDK was compiled.
Android CI separately builds against the pinned upstream llama.cpp source.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ADAPTER = ROOT / "native" / "llama" / "src" / "llama_probe.cpp"

FAKE_HEADER = r'''#pragma once
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

using llama_token = std::int32_t;
using llama_pos = std::int32_t;
using llama_seq_id = std::int32_t;
#define LLAMA_TOKEN_NULL (-1)
#define LLAMA_DEFAULT_SEED 0xFFFFFFFFU

struct llama_vocab {};
struct llama_memory_i {};
using llama_memory_t = llama_memory_i *;
struct llama_model_params { std::int32_t n_gpu_layers; bool check_tensors; };
struct llama_context_params {
    std::uint32_t n_ctx;
    std::uint32_t n_batch;
    std::uint32_t n_ubatch;
    std::uint32_t n_seq_max;
    std::int32_t n_threads;
    std::int32_t n_threads_batch;
    bool (*abort_callback)(void *);
    void *abort_callback_data;
};
struct llama_model { std::string path; };
struct llama_context {
    std::uint32_t context_tokens;
    llama_model *model;
    llama_memory_i memory;
    std::int32_t decode_calls;
    bool (*abort_callback)(void *);
    void *abort_callback_data;
};
struct llama_chat_message { const char *role; const char *content; };
struct llama_batch {
    std::int32_t n_tokens;
    llama_token *token;
    float *embd;
    llama_pos *pos;
    std::int32_t *n_seq_id;
    llama_seq_id **seq_id;
    std::int8_t *logits;
};
struct llama_sampler { std::vector<llama_sampler *> children; std::uint32_t sample_index; bool chain; };

llama_model_params llama_model_default_params();
llama_context_params llama_context_default_params();
void llama_backend_init();
const char *llama_version();
llama_model *llama_model_load_from_file(const char *, llama_model_params);
void llama_model_free(llama_model *);
llama_context *llama_init_from_model(llama_model *, llama_context_params);
void llama_free(llama_context *);
std::uint32_t llama_n_ctx(const llama_context *);
bool llama_model_has_decoder(const llama_model *);
bool llama_model_has_encoder(const llama_model *);
bool llama_model_is_diffusion(const llama_model *);
const llama_vocab *llama_model_get_vocab(const llama_model *);
const char *llama_model_chat_template(const llama_model *, const char *);
std::int32_t llama_chat_apply_template(const char *, const llama_chat_message *, std::size_t, bool, char *, std::int32_t);
std::int32_t llama_tokenize(const llama_vocab *, const char *, std::int32_t, llama_token *, std::int32_t, bool, bool);
std::int32_t llama_token_to_piece(const llama_vocab *, llama_token, char *, std::int32_t, std::int32_t, bool);
bool llama_vocab_is_eog(const llama_vocab *, llama_token);
llama_token llama_vocab_bos(const llama_vocab *);
bool llama_vocab_get_add_bos(const llama_vocab *);
llama_batch llama_batch_init(std::int32_t, std::int32_t, std::int32_t);
void llama_batch_free(llama_batch);
std::int32_t llama_decode(llama_context *, llama_batch);
llama_memory_t llama_get_memory(llama_context *);
void llama_memory_clear(llama_memory_t, bool);
llama_sampler *llama_sampler_chain_init(int);
int llama_sampler_chain_default_params();
void llama_sampler_chain_add(llama_sampler *, llama_sampler *);
llama_sampler *llama_sampler_init_top_k(std::int32_t);
llama_sampler *llama_sampler_init_top_p(float, std::size_t);
llama_sampler *llama_sampler_init_temp(float);
llama_sampler *llama_sampler_init_dist(std::uint32_t);
llama_token llama_sampler_sample(llama_sampler *, llama_context *, std::int32_t);
void llama_sampler_free(llama_sampler *);
'''

FAKE_IMPLEMENTATION = r'''#include "llama.h"
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <new>

namespace { const llama_vocab vocab{}; std::string last_tokenized_prompt; }
llama_model_params llama_model_default_params() { return llama_model_params{0, false}; }
llama_context_params llama_context_default_params() { return llama_context_params{512, 128, 128, 1, 2, 2, nullptr, nullptr}; }
void llama_backend_init() {}
const char *llama_version() { return "fake-llama-contract"; }
llama_model *llama_model_load_from_file(const char *path, llama_model_params params) {
    if (path == nullptr || params.n_gpu_layers != 0) return nullptr;
    if (std::string(path).find("bad_model") != std::string::npos) return nullptr;
    return new (std::nothrow) llama_model{path};
}
void llama_model_free(llama_model *model) { delete model; }
llama_context *llama_init_from_model(llama_model *model, llama_context_params params) {
    if (model == nullptr || params.n_ctx == 0 || model->path.find("bad_context") != std::string::npos) return nullptr;
    return new (std::nothrow) llama_context{
        params.n_ctx, model, {}, 0, params.abort_callback, params.abort_callback_data
    };
}
void llama_free(llama_context *context) { delete context; }
std::uint32_t llama_n_ctx(const llama_context *context) { return context == nullptr ? 0 : context->context_tokens; }
bool llama_model_has_decoder(const llama_model *) { return true; }
bool llama_model_has_encoder(const llama_model *model) { return model && model->path.find("encoder") != std::string::npos; }
bool llama_model_is_diffusion(const llama_model *) { return false; }
const llama_vocab *llama_model_get_vocab(const llama_model *) { return &vocab; }
const char *llama_model_chat_template(const llama_model *, const char *) { return "fake-template"; }
std::int32_t llama_chat_apply_template(const char *, const llama_chat_message *messages,
                                       std::size_t count, bool add_ass, char *buffer,
                                       std::int32_t length) {
    std::string formatted;
    for (std::size_t i = 0; i < count; ++i) {
        formatted += messages[i].role;
        formatted += ":";
        formatted += messages[i].content;
        formatted += "\n";
    }
    if (add_ass) formatted += "assistant:";
    if (formatted.size() > static_cast<std::size_t>(length)) return static_cast<std::int32_t>(formatted.size());
    std::memcpy(buffer, formatted.data(), formatted.size());
    return static_cast<std::int32_t>(formatted.size());
}
extern "C" const char *nexus_test_last_tokenized_prompt() { return last_tokenized_prompt.c_str(); }
std::int32_t llama_tokenize(const llama_vocab *, const char *text, std::int32_t text_len,
                            llama_token *tokens, std::int32_t max_tokens, bool, bool) {
    if (text_len < 0) return -1;
    last_tokenized_prompt.assign(text, static_cast<std::size_t>(text_len));
    if (max_tokens < text_len) return -text_len;
    for (std::int32_t i = 0; i < text_len; ++i) tokens[i] = 0x100 + static_cast<unsigned char>(text[i]);
    return text_len;
}
std::int32_t llama_token_to_piece(const llama_vocab *, llama_token token, char *buffer,
                                  std::int32_t size, std::int32_t, bool) {
    static constexpr char response[] = "NEXUS";
    if (token < 10 || token >= 15) return -1;
    if (size < 1) return -1;
    buffer[0] = response[token - 10];
    return 1;
}
bool llama_vocab_is_eog(const llama_vocab *, llama_token token) { return token == 0; }
llama_token llama_vocab_bos(const llama_vocab *) { return 1; }
bool llama_vocab_get_add_bos(const llama_vocab *) { return true; }
llama_batch llama_batch_init(std::int32_t count, std::int32_t, std::int32_t seq_count) {
    llama_batch batch{};
    batch.n_tokens = 0;
    batch.token = new (std::nothrow) llama_token[count]{};
    batch.pos = new (std::nothrow) llama_pos[count]{};
    batch.n_seq_id = new (std::nothrow) std::int32_t[count]{};
    batch.seq_id = new (std::nothrow) llama_seq_id *[count]{};
    batch.logits = new (std::nothrow) std::int8_t[count]{};
    for (std::int32_t i = 0; i < count; ++i) batch.seq_id[i] = new (std::nothrow) llama_seq_id[seq_count]{};
    return batch;
}
void llama_batch_free(llama_batch batch) {
    if (batch.seq_id) { for (std::int32_t i = 0; i < 128; ++i) delete[] batch.seq_id[i]; }
    delete[] batch.seq_id; delete[] batch.token; delete[] batch.pos;
    delete[] batch.n_seq_id; delete[] batch.logits;
}
std::int32_t llama_decode(llama_context *context, llama_batch batch) {
    if (!context || batch.n_tokens <= 0) return -1;
    if (context->abort_callback && context->abort_callback(context->abort_callback_data)) return 2;
    if (context->model && context->model->path.find("abort_decode") != std::string::npos &&
        context->decode_calls > 0) return 2;
    ++context->decode_calls;
    return 0;
}
llama_memory_t llama_get_memory(llama_context *context) { return context ? &context->memory : nullptr; }
void llama_memory_clear(llama_memory_t, bool) {}
llama_sampler *llama_sampler_chain_init(int) { return new (std::nothrow) llama_sampler{{}, 0, true}; }
int llama_sampler_chain_default_params() { return 0; }
void llama_sampler_chain_add(llama_sampler *chain, llama_sampler *step) { if (chain && step) chain->children.push_back(step); }
llama_sampler *llama_sampler_init_top_k(std::int32_t) { return new (std::nothrow) llama_sampler{{}, 0, false}; }
llama_sampler *llama_sampler_init_top_p(float, std::size_t) { return new (std::nothrow) llama_sampler{{}, 0, false}; }
llama_sampler *llama_sampler_init_temp(float) { return new (std::nothrow) llama_sampler{{}, 0, false}; }
llama_sampler *llama_sampler_init_dist(std::uint32_t) { return new (std::nothrow) llama_sampler{{}, 0, false}; }
llama_token llama_sampler_sample(llama_sampler *chain, llama_context *, std::int32_t) {
    static constexpr llama_token output[] = {10, 11, 12, 13, 14, 0};
    if (!chain) return LLAMA_TOKEN_NULL;
    const auto index = chain->sample_index++;
    return output[index < 6 ? index : 5];
}
void llama_sampler_free(llama_sampler *sampler) {
    if (!sampler) return;
    for (auto *child : sampler->children) delete child;
    delete sampler;
}
'''

TEST_SOURCE = r'''#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <unistd.h>

using TokenCallback = std::int32_t (*)(const char *, std::size_t, std::uint32_t, void *);
struct NexusChatMessage { const char *role; const char *content; };
extern "C" {
std::int32_t nexus_llama_backend_init() noexcept;
const char *nexus_llama_version() noexcept;
std::int32_t nexus_llama_load_model(const char *, std::uint32_t, std::int32_t, std::uint32_t *) noexcept;
std::int32_t nexus_llama_unload_model() noexcept;
std::int32_t nexus_llama_is_model_loaded() noexcept;
std::uint32_t nexus_llama_loaded_context_tokens() noexcept;
std::int32_t nexus_llama_inference_available() noexcept;
std::int32_t nexus_llama_cancel_generation() noexcept;
std::int32_t nexus_llama_generate(const NexusChatMessage *, std::size_t, std::uint32_t, float,
                                  std::uint32_t, float, std::uint32_t, TokenCallback, void *,
                                  std::uint32_t *, std::uint32_t *) noexcept;
const char *nexus_llama_last_error() noexcept;
const char *nexus_test_last_tokenized_prompt();
}
struct Capture {
    std::string text;
    bool cancel_first = false;
    bool cancel_on_start = false;
    int start_events = 0;
};
static std::int32_t capture_piece(const char *data, std::size_t size, std::uint32_t generated, void *opaque) {
    auto *capture = static_cast<Capture *>(opaque);
    if (size == 0 && data == nullptr && generated == 0) {
        ++capture->start_events;
        if (capture->cancel_on_start) {
            capture->cancel_on_start = false;
            assert(nexus_llama_cancel_generation() == 1);
        }
        return 1;
    }
    if (size > 0) capture->text.append(data, size);
    if (size > 0 && capture->cancel_first) {
        capture->cancel_first = false;
        assert(nexus_llama_cancel_generation() == 1);
    }
    return 1;
}
static std::string make_file(const char *prefix) {
    char path[256];
    std::snprintf(path, sizeof(path), "/tmp/%s-XXXXXX.gguf", prefix);
    const int fd = mkstemps(path, 5);
    assert(fd >= 0);
    const char payload[] = "NEXUS-GGUF-TEST";
    assert(write(fd, payload, sizeof(payload)) == static_cast<ssize_t>(sizeof(payload)));
    close(fd);
    return path;
}
int main() {
    assert(nexus_llama_backend_init() == 1);
    assert(std::string(nexus_llama_version()) == "fake-llama-contract");
    assert(nexus_llama_is_model_loaded() == 0);
    assert(nexus_llama_inference_available() == 0);

    Capture empty_capture{};
    std::uint32_t generated = 0;
    std::uint32_t trimmed = 0;
    const NexusChatMessage hello[] = {{"user", "Hello"}};
    assert(nexus_llama_generate(hello, 1, 16, 0.7F, 40, 0.92F, 0,
                                capture_piece, &empty_capture, &generated, &trimmed) == -2);
    assert(nexus_llama_cancel_generation() == 0);

    const auto model_a = make_file("nexus-model-a");
    const auto model_b = make_file("nexus-model-b");
    std::uint32_t actual_context = 0;
    assert(setenv("NEXUS_TEST_AVAILABLE_MEMORY_KIB", "1048576", 1) == 0);
    assert(nexus_llama_load_model(model_a.c_str(), 2048, 4, &actual_context) == 1);
    assert(actual_context == 2048);
    assert(nexus_llama_is_model_loaded() == 1);
    assert(nexus_llama_loaded_context_tokens() == 2048);

    actual_context = 0;
    assert(nexus_llama_load_model(model_a.c_str(), 2048, 4, &actual_context) == 1);
    assert(actual_context == 2048);
    assert(nexus_llama_load_model(model_a.c_str(), 2048, 3, &actual_context) == -4);
    assert(nexus_llama_load_model(model_b.c_str(), 2048, 4, &actual_context) == -4);
    assert(nexus_llama_is_model_loaded() == 1);

    Capture cancelled_before_tokens{};
    cancelled_before_tokens.cancel_on_start = true;
    generated = 0;
    const NexusChatMessage stop_before[] = {{"user", "Stop before prompt evaluation"}};
    assert(nexus_llama_generate(stop_before, 1, 32, 0.7F, 40, 0.92F, 7,
                                capture_piece, &cancelled_before_tokens, &generated, &trimmed) == 2);
    assert(cancelled_before_tokens.text.empty());
    assert(cancelled_before_tokens.start_events == 1);
    assert(generated == 0);
    assert(nexus_llama_cancel_generation() == 0);
    assert(nexus_llama_inference_available() == 0);

    Capture cancelled{};
    cancelled.cancel_first = true;
    generated = 0;
    const NexusChatMessage stop_after[] = {{"user", "Stop after first token"}};
    assert(nexus_llama_generate(stop_after, 1, 32, 0.7F, 40, 0.92F, 7,
                                capture_piece, &cancelled, &generated, &trimmed) == 2);
    assert(cancelled.text == "N");
    assert(cancelled.start_events == 1);
    assert(generated == 1);
    assert(nexus_llama_cancel_generation() == 0);
    assert(nexus_llama_inference_available() == 0);

    Capture response{};
    generated = 0;
    assert(nexus_llama_generate(hello, 1, 32, 0.7F, 40, 0.92F, 7,
                                capture_piece, &response, &generated, &trimmed) == 1);
    assert(response.text == "NEXUS");
    assert(response.start_events == 1);
    assert(generated == 5);
    assert(nexus_llama_inference_available() == 1);

    const NexusChatMessage multi_turn[] = {
        {"system", "Answer accurately."},
        {"user", "Remember the number 42."},
        {"assistant", "I will remember 42."},
        {"user", "What number did I ask you to remember?"}
    };
    assert(nexus_llama_generate(multi_turn, 4, 32, 0.7F, 40, 0.92F, 7,
                                capture_piece, &response, &generated, &trimmed) == 1);
    assert(trimmed == 0);
    const std::string formatted_multi_turn(nexus_test_last_tokenized_prompt());
    assert(formatted_multi_turn.find("system:Answer accurately.") != std::string::npos);
    assert(formatted_multi_turn.find("assistant:I will remember 42.") != std::string::npos);
    assert(formatted_multi_turn.find("What number did I ask you to remember?") != std::string::npos);

    const NexusChatMessage invalid_last_role[] = {
        {"user", "question"}, {"assistant", "not a current user turn"}
    };
    assert(nexus_llama_generate(invalid_last_role, 2, 32, 0.7F, 40, 0.92F, 7,
                                capture_piece, &response, &generated, &trimmed) == -1);

    assert(nexus_llama_generate(nullptr, 1, 16, 0.7F, 40, 0.92F, 0,
                                capture_piece, &response, &generated, &trimmed) == -1);
    assert(nexus_llama_generate(hello, 1, 1025, 0.7F, 40, 0.92F, 0,
                                capture_piece, &response, &generated, &trimmed) == -1);
    assert(nexus_llama_generate(hello, 1, 16, 3.0F, 40, 0.92F, 0,
                                capture_piece, &response, &generated, &trimmed) == -1);

    const std::string too_long_for_context(2000, 'x');
    const NexusChatMessage long_prompt[] = {{"user", too_long_for_context.c_str()}};
    assert(nexus_llama_generate(long_prompt, 1, 100, 0.7F, 40, 0.92F, 0,
                                capture_piece, &response, &generated, &trimmed) == -4);

    // Multi-turn role order reaches the adapter and old complete turns are
    // pruned until the current user message fits.
    const NexusChatMessage long_history[] = {
        {"user", too_long_for_context.c_str()}, {"assistant", "An old answer"},
        {"user", "Current question"}
    };
    assert(nexus_llama_generate(long_history, 3, 100, 0.7F, 40, 0.92F, 0,
                                capture_piece, &response, &generated, &trimmed) == 1);
    assert(trimmed == 2);
    assert(response.text.find("NEXUS") != std::string::npos);
    assert(std::string(nexus_test_last_tokenized_prompt()).find("Current question") != std::string::npos);
    assert(std::string(nexus_test_last_tokenized_prompt()).find(std::string(2000, 'x')) == std::string::npos);

    assert(nexus_llama_unload_model() == 1);
    assert(nexus_llama_is_model_loaded() == 0);
    assert(nexus_llama_loaded_context_tokens() == 0);
    assert(nexus_llama_inference_available() == 0);
    assert(nexus_llama_unload_model() == 1);

    assert(nexus_llama_load_model(model_a.c_str(), 256, 4, &actual_context) == -1);
    assert(nexus_llama_load_model(model_a.c_str(), 2048, 0, &actual_context) == -1);
    assert(nexus_llama_load_model("/tmp/nexus-missing-file.gguf", 2048, 4, &actual_context) == -2);
    const auto bad_model = make_file("nexus-bad_model");
    assert(nexus_llama_load_model(bad_model.c_str(), 2048, 4, &actual_context) == -5);
    const auto bad_context = make_file("nexus-bad_context");
    assert(nexus_llama_load_model(bad_context.c_str(), 2048, 4, &actual_context) == -6);

    assert(setenv("NEXUS_TEST_AVAILABLE_MEMORY_KIB", "1", 1) == 0);
    assert(nexus_llama_load_model(model_a.c_str(), 2048, 4, &actual_context) == -3);
    assert(std::string(nexus_llama_last_error()).find("الذاكرة") != std::string::npos);
    assert(unsetenv("NEXUS_TEST_AVAILABLE_MEMORY_KIB") == 0);

    unlink(model_a.c_str()); unlink(model_b.c_str()); unlink(bad_model.c_str()); unlink(bad_context.c_str());
    std::puts("NEXUS llama adapter C ABI generation contract: PASS");
    return 0;
}
'''


def run(command: list[str], *, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    print("$", " ".join(command))
    result = subprocess.run(command, cwd=cwd, text=True, capture_output=True)
    if result.stdout:
        print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="")
    if result.returncode:
        raise SystemExit(result.returncode)
    return result


def main() -> None:
    compiler = shutil.which("c++") or shutil.which("clang++")
    if not compiler:
        raise SystemExit("A C++17 compiler (c++ or clang++) is required for the adapter contract test.")
    if not ADAPTER.is_file():
        raise SystemExit(f"Adapter source is missing: {ADAPTER}")

    with tempfile.TemporaryDirectory(prefix="nexus-llama-contract-") as temp:
        directory = Path(temp)
        include = directory / "include"
        include.mkdir()
        (include / "llama.h").write_text(FAKE_HEADER, encoding="utf-8")
        implementation = directory / "fake_llama.cpp"
        implementation.write_text(FAKE_IMPLEMENTATION, encoding="utf-8")
        test_source = directory / "contract_test.cpp"
        test_source.write_text(TEST_SOURCE, encoding="utf-8")
        shared_library = directory / "libnexus_probe_contract.so"
        executable = directory / "contract_test"

        run([
            compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror", "-fPIC", "-shared",
            "-DNEXUS_TESTING", "-pthread", "-I", str(include), str(ADAPTER), str(implementation),
            "-o", str(shared_library),
        ])
        run([
            compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror", "-pthread",
            str(test_source), "-L", str(directory), "-lnexus_probe_contract",
            f"-Wl,-rpath,{directory}", "-o", str(executable),
        ])
        run([str(executable)])

        nm = shutil.which("nm")
        if nm:
            symbols = run([nm, "-D", "--defined-only", str(shared_library)]).stdout
            required = (
                "nexus_llama_backend_init", "nexus_llama_version", "nexus_llama_load_model",
                "nexus_llama_inference_available", "nexus_llama_cancel_generation",
                "nexus_llama_generate", "nexus_llama_unload_model", "nexus_llama_is_model_loaded",
                "nexus_llama_loaded_context_tokens", "nexus_llama_last_error",
            )
            missing = [symbol for symbol in required if symbol not in symbols]
            if missing:
                raise SystemExit("Missing exported C ABI symbols: " + ", ".join(missing))
            print(f"Verified {len(required)} exported NEXUS C ABI symbols.")

    print("Host-side native adapter contract checks passed (fake llama API only).")


if __name__ == "__main__":
    main()
