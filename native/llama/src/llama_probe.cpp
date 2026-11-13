#include "llama.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <exception>
#include <fstream>
#include <limits>
#include <mutex>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <vector>

#if defined(__GNUC__)
#define NEXUS_EXPORT __attribute__((visibility("default")))
#else
#define NEXUS_EXPORT
#endif

namespace {
constexpr std::uint64_t kMiB = 1024ULL * 1024ULL;
constexpr std::uint64_t kBaseReserveBytes = 384ULL * kMiB;
constexpr std::uint64_t kContextReservePer2kBytes = 128ULL * kMiB;
constexpr std::uint32_t kMinContextTokens = 512;
constexpr std::uint32_t kMaxContextTokens = 4096;
constexpr std::int32_t kMaxThreads = 8;
constexpr std::size_t kMaxPromptBytes = 16U * 1024U;
constexpr std::uint32_t kMaxGenerationTokens = 1024;
constexpr std::uint32_t kPromptBatchTokens = 128;
constexpr std::size_t kMaxFormattedPromptBytes = 64U * 1024U;

struct LoadedSession {
    struct llama_model *model = nullptr;
    struct llama_context *context = nullptr;
    std::string path;
    std::uint32_t context_tokens = 0;
    std::int32_t threads = 0;
};

std::once_flag backend_initialized;
std::mutex session_mutex;
std::atomic<bool> generation_active{false};
std::atomic<bool> cancellation_requested{false};
std::atomic<bool> inference_verified{false};
LoadedSession session;
thread_local std::string last_error;

void set_error(const char *message) noexcept {
    try {
        last_error = message == nullptr ? "" : message;
    } catch (...) {
        last_error.clear();
    }
}

void set_error(const std::string &message) noexcept {
    try {
        last_error = message;
    } catch (...) {
        last_error.clear();
    }
}

bool read_available_memory(std::uint64_t &bytes) {
#if defined(NEXUS_TESTING)
    // Test-only injection keeps the production adapter free of runtime overrides.
    if (const char *override_kib = std::getenv("NEXUS_TEST_AVAILABLE_MEMORY_KIB")) {
        char *end = nullptr;
        const auto kib = std::strtoull(override_kib, &end, 10);
        if (end == override_kib || *end != '\0' || kib == 0 || kib > UINT64_MAX / 1024ULL) {
            return false;
        }
        bytes = kib * 1024ULL;
        return true;
    }
#endif
    std::ifstream meminfo("/proc/meminfo");
    if (!meminfo.is_open()) {
        return false;
    }

    std::string line;
    while (std::getline(meminfo, line)) {
        if (line.compare(0, 13, "MemAvailable:") != 0) {
            continue;
        }
        std::istringstream values(line.substr(13));
        std::uint64_t kib = 0;
        if (!(values >> kib) || kib == 0 || kib > UINT64_MAX / 1024ULL) {
            return false;
        }
        bytes = kib * 1024ULL;
        return true;
    }
    return false;
}

bool has_sufficient_memory(std::uint64_t model_bytes, std::uint32_t context_tokens,
                           std::uint64_t available, std::uint64_t &required) {
    const std::uint64_t model_margin = model_bytes / 8ULL;
    const std::uint64_t context_units =
        (static_cast<std::uint64_t>(context_tokens) + 2047ULL) / 2048ULL;
    const std::uint64_t context_reserve = context_units * kContextReservePer2kBytes;
    if (model_bytes > UINT64_MAX - model_margin - kBaseReserveBytes - context_reserve) {
        return false;
    }
    required = model_bytes + model_margin + kBaseReserveBytes + context_reserve;
    return available >= required;
}

bool should_abort_compute(void *) noexcept {
    return cancellation_requested.load(std::memory_order_acquire);
}

using TokenPieceCallback = std::int32_t (*)(
    const char *, std::size_t, std::uint32_t, void *);

struct GenerationLifecycle {
    GenerationLifecycle() noexcept {
        cancellation_requested.store(false, std::memory_order_release);
        generation_active.store(true, std::memory_order_release);
    }
    ~GenerationLifecycle() {
        generation_active.store(false, std::memory_order_release);
        cancellation_requested.store(false, std::memory_order_release);
    }
    GenerationLifecycle(const GenerationLifecycle &) = delete;
    GenerationLifecycle &operator=(const GenerationLifecycle &) = delete;
};

struct ContextMemoryReset {
    explicit ContextMemoryReset(llama_context *value) noexcept : context(value) {
        if (context != nullptr) {
            const auto memory = llama_get_memory(context);
            if (memory != nullptr) {
                llama_memory_clear(memory, true);
            }
        }
    }
    ~ContextMemoryReset() {
        if (context != nullptr) {
            const auto memory = llama_get_memory(context);
            if (memory != nullptr) {
                llama_memory_clear(memory, true);
            }
        }
    }
    llama_context *context;
};

struct SamplerGuard {
    explicit SamplerGuard(llama_sampler *value) noexcept : sampler(value) {}
    ~SamplerGuard() {
        if (sampler != nullptr) {
            llama_sampler_free(sampler);
        }
    }
    llama_sampler *sampler;
};

struct BatchGuard {
    explicit BatchGuard(llama_batch value) noexcept : batch(value) {}
    ~BatchGuard() { llama_batch_free(batch); }
    llama_batch batch;
};

void release_session_locked() {
    inference_verified.store(false, std::memory_order_release);
    if (session.context != nullptr) {
        llama_free(session.context);
        session.context = nullptr;
    }
    if (session.model != nullptr) {
        llama_model_free(session.model);
        session.model = nullptr;
    }
    session.path.clear();
    session.context_tokens = 0;
    session.threads = 0;
}
}  // namespace

extern "C" {

// Initializes llama.cpp once per process. It does not imply that a model is loaded.
NEXUS_EXPORT std::int32_t nexus_llama_backend_init() noexcept {
    try {
        std::call_once(backend_initialized, []() { llama_backend_init(); });
        return 1;
    } catch (...) {
        set_error("تعذرت تهيئة llama.cpp backend.");
        return 0;
    }
}

// llama_version() returns a process-lifetime string owned by llama.cpp.
NEXUS_EXPORT const char *nexus_llama_version() noexcept {
    return llama_version();
}

// Load one local GGUF model and allocate one CPU inference context.
// The function never replaces an already active model implicitly.
NEXUS_EXPORT std::int32_t nexus_llama_load_model(
    const char *path, std::uint32_t context_tokens, std::int32_t threads,
    std::uint32_t *actual_context_tokens) noexcept {
    try {
        if (actual_context_tokens != nullptr) {
            *actual_context_tokens = 0;
        }
        if (path == nullptr || path[0] == '\0') {
            set_error("مسار ملف GGUF فارغ.");
            return -1;
        }
        if (context_tokens < kMinContextTokens || context_tokens > kMaxContextTokens) {
            set_error("حجم السياق المطلوب خارج النطاق المدعوم (512–4096).");
            return -1;
        }
        if (threads < 1 || threads > kMaxThreads) {
            set_error("عدد خيوط CPU يجب أن يكون بين 1 و8.");
            return -1;
        }
        if (nexus_llama_backend_init() != 1) {
            set_error("تعذرت تهيئة llama.cpp backend.");
            return -5;
        }

        const std::string model_path(path);
        // Allocate/copy all C++ path storage before llama.cpp allocates model memory.
        // Swapping this string into the active session after successful loading is noexcept.
        std::string active_path = model_path;
        struct stat file_status {};
        if (::stat(path, &file_status) != 0 || !S_ISREG(file_status.st_mode) ||
            file_status.st_size <= 0) {
            set_error("ملف GGUF غير موجود أو ليس ملفاً عادياً أو حجمه صفر.");
            return -2;
        }
        const auto model_bytes = static_cast<std::uint64_t>(file_status.st_size);

        std::lock_guard<std::mutex> lock(session_mutex);
        if (session.model != nullptr || session.context != nullptr) {
            if (session.path == model_path && session.context_tokens == context_tokens &&
                session.threads == threads && session.model != nullptr && session.context != nullptr) {
                if (actual_context_tokens != nullptr) {
                    *actual_context_tokens = session.context_tokens;
                }
                last_error.clear();
                return 1;
            }
            set_error("يوجد نموذج آخر محمّل بالفعل. أفرغه قبل تحميل نموذج مختلف.");
            return -4;
        }

        std::uint64_t available_bytes = 0;
        std::uint64_t required_bytes = 0;
        if (!read_available_memory(available_bytes)) {
            set_error("تعذر قياس الذاكرة المتاحة من /proc/meminfo؛ تم إيقاف التحميل لتجنب نفاد الذاكرة.");
            return -3;
        }
        if (!has_sufficient_memory(model_bytes, context_tokens, available_bytes, required_bytes)) {
            std::ostringstream message;
            message << "الذاكرة المتاحة (" << (available_bytes / kMiB)
                    << " MiB) أقل من الحد المحافظ المطلوب (" << (required_bytes / kMiB)
                    << " MiB). أغلق التطبيقات الأخرى أو اختر نموذجاً أصغر.";
            set_error(message.str());
            return -3;
        }

        llama_model_params model_params = llama_model_default_params();
        model_params.n_gpu_layers = 0;  // CPU-only on the first Android runtime.
        model_params.check_tensors = true;
        struct llama_model *model = llama_model_load_from_file(path, model_params);
        if (model == nullptr) {
            set_error("رفض llama.cpp تحميل ملف GGUF. تحقق من سلامة الملف وتوافق بنيته.");
            return -5;
        }

        llama_context_params context_params = llama_context_default_params();
        context_params.n_ctx = context_tokens;
        context_params.n_batch = 128;
        context_params.n_ubatch = 128;
        context_params.n_seq_max = 1;
        context_params.n_threads = threads;
        context_params.n_threads_batch = threads;
        context_params.abort_callback = should_abort_compute;
        context_params.abort_callback_data = nullptr;
        struct llama_context *context = llama_init_from_model(model, context_params);
        if (context == nullptr) {
            llama_model_free(model);
            set_error("تم فتح أوزان النموذج لكن تعذر إنشاء سياق التشغيل؛ خفّض حجم السياق أو استخدم نموذجاً أصغر.");
            return -6;
        }

        const std::uint32_t loaded_context_tokens = llama_n_ctx(context);
        if (loaded_context_tokens == 0) {
            llama_free(context);
            llama_model_free(model);
            set_error("أنشأ llama.cpp سياقاً غير صالح بحجم صفري.");
            return -6;
        }

        session.model = model;
        session.context = context;
        session.path.swap(active_path);
        session.context_tokens = loaded_context_tokens;
        session.threads = threads;
        if (actual_context_tokens != nullptr) {
            *actual_context_tokens = loaded_context_tokens;
        }
        last_error.clear();
        return 1;
    } catch (const std::exception &error) {
        try {
            set_error(std::string("استثناء أثناء تحميل GGUF: ") + error.what());
        } catch (...) {
            set_error("نفدت الذاكرة أثناء إعداد رسالة خطأ تحميل GGUF.");
        }
        return -7;
    } catch (...) {
        set_error("حدث خطأ غير معروف أثناء تحميل GGUF.");
        return -7;
    }
}


// This flag belongs to the currently loaded model, not to the process lifetime.
NEXUS_EXPORT std::int32_t nexus_llama_inference_available() noexcept {
    // release_session_locked() resets this before the model is freed, so the
    // diagnostics query can remain lock-free while generation is running.
    return inference_verified.load(std::memory_order_acquire) ? 1 : 0;
}

// A cancellation request must never wait for session_mutex: generation holds
// that mutex for its full lifetime so unload/load cannot free active weights.
NEXUS_EXPORT std::int32_t nexus_llama_cancel_generation() noexcept {
    if (!generation_active.load(std::memory_order_acquire)) {
        return 0;
    }
    cancellation_requested.store(true, std::memory_order_release);
    return 1;
}

NEXUS_EXPORT std::int32_t nexus_llama_generate(
    const char *prompt,
    std::uint32_t max_tokens,
    float temperature,
    std::uint32_t top_k,
    float top_p,
    std::uint32_t seed,
    TokenPieceCallback on_token_piece,
    void *user_data,
    std::uint32_t *generated_tokens) noexcept {
    try {
        if (generated_tokens != nullptr) {
            *generated_tokens = 0;
        }
        if (prompt == nullptr || prompt[0] == '\0') {
            set_error("أدخل نصاً غير فارغ قبل بدء التوليد.");
            return -1;
        }
        if (on_token_piece == nullptr) {
            set_error("قناة استقبال رموز التوليد غير متاحة.");
            return -1;
        }
        if (max_tokens < 1 || max_tokens > kMaxGenerationTokens) {
            set_error("عدد رموز الإخراج يجب أن يكون بين 1 و1024.");
            return -1;
        }
        if (!std::isfinite(temperature) || temperature < 0.05F || temperature > 2.0F) {
            set_error("درجة الحرارة يجب أن تكون بين 0.05 و2.0.");
            return -1;
        }
        if (top_k < 1 || top_k > 100) {
            set_error("قيمة Top-K يجب أن تكون بين 1 و100.");
            return -1;
        }
        if (!std::isfinite(top_p) || top_p < 0.1F || top_p > 1.0F) {
            set_error("قيمة Top-P يجب أن تكون بين 0.1 و1.0.");
            return -1;
        }

        const std::string prompt_text(prompt);
        if (prompt_text.size() > kMaxPromptBytes) {
            set_error("النص المدخل أطول من الحد المسموح (16 كيلوبايت).");
            return -1;
        }

        std::lock_guard<std::mutex> lock(session_mutex);
        if (session.model == nullptr || session.context == nullptr) {
            set_error("حمّل نموذج GGUF أولاً قبل بدء التوليد.");
            return -2;
        }

        GenerationLifecycle generation_lifecycle;
        // Signal that native generation is now active before prompt evaluation.
        // This lets the UI expose Stop while a large prompt is being evaluated.
        if (on_token_piece(nullptr, 0, 0, user_data) == 0) {
            set_error("تعذر بدء تدفق التوليد إلى الواجهة.");
            return -8;
        }
        ContextMemoryReset memory_reset(session.context);
        if (!llama_model_has_decoder(session.model) ||
            llama_model_has_encoder(session.model) ||
            llama_model_is_diffusion(session.model)) {
            set_error("هذا الإصدار يدعم نماذج المحادثة ذات Decoder فقط؛ نماذج Encoder/Decoder أو Diffusion غير مدعومة بعد.");
            return -3;
        }
        const auto *vocab = llama_model_get_vocab(session.model);
        if (vocab == nullptr) {
            set_error("تعذر الوصول إلى مفردات النموذج.");
            return -3;
        }

        std::string formatted_prompt = prompt_text;
        const char *chat_template = llama_model_chat_template(session.model, nullptr);
        if (chat_template != nullptr && chat_template[0] != '\0') {
            llama_chat_message message{};
            message.role = "user";
            message.content = prompt_text.c_str();
            std::vector<char> template_buffer(
                std::min(kMaxFormattedPromptBytes, prompt_text.size() * 2U + 2048U));
            if (template_buffer.empty()) {
                set_error("تعذر حجز ذاكرة لتنسيق رسالة النموذج.");
                return -3;
            }
            std::int32_t formatted_size = llama_chat_apply_template(
                chat_template, &message, 1, true, template_buffer.data(),
                static_cast<std::int32_t>(template_buffer.size()));
            if (formatted_size < 0) {
                set_error("تعذر تطبيق قالب المحادثة المضمن في النموذج.");
                return -3;
            }
            if (static_cast<std::size_t>(formatted_size) > template_buffer.size()) {
                if (static_cast<std::size_t>(formatted_size) > kMaxFormattedPromptBytes) {
                    set_error("قالب المحادثة الناتج تجاوز الحد الآمن لحجم الإدخال.");
                    return -3;
                }
                template_buffer.resize(static_cast<std::size_t>(formatted_size) + 1U);
                formatted_size = llama_chat_apply_template(
                    chat_template, &message, 1, true, template_buffer.data(),
                    static_cast<std::int32_t>(template_buffer.size()));
                if (formatted_size < 0 ||
                    static_cast<std::size_t>(formatted_size) > template_buffer.size()) {
                    set_error("فشل إنشاء Prompt صالح باستخدام قالب النموذج.");
                    return -3;
                }
            }
            formatted_prompt.assign(template_buffer.data(), static_cast<std::size_t>(formatted_size));
        }

        if (formatted_prompt.empty() || formatted_prompt.size() > kMaxFormattedPromptBytes ||
            formatted_prompt.size() > static_cast<std::size_t>(std::numeric_limits<std::int32_t>::max())) {
            set_error("حجم Prompt النهائي خارج النطاق الآمن.");
            return -3;
        }

        // Parse template control tokens but do not ask llama_tokenize to append
        // model-configured EOS tokens. Insert BOS explicitly only when needed;
        // this avoids both a missing BOS and a duplicate BOS from chat templates.
        std::vector<llama_token> prompt_tokens(formatted_prompt.size() + 8U);
        std::int32_t prompt_token_count = llama_tokenize(
            vocab, formatted_prompt.data(), static_cast<std::int32_t>(formatted_prompt.size()),
            prompt_tokens.data(), static_cast<std::int32_t>(prompt_tokens.size()), false, true);
        if (prompt_token_count < 0) {
            if (prompt_token_count == std::numeric_limits<std::int32_t>::min()) {
                set_error("تجاوزت نتيجة تقطيع Prompt الحد العددي المدعوم.");
                return -3;
            }
            const auto required = static_cast<std::size_t>(-prompt_token_count);
            if (required == 0 || required > kMaxFormattedPromptBytes + 8U) {
                set_error("تعذر تحديد حجم Tokens المطلوب للمدخل.");
                return -3;
            }
            prompt_tokens.resize(required);
            prompt_token_count = llama_tokenize(
                vocab, formatted_prompt.data(), static_cast<std::int32_t>(formatted_prompt.size()),
                prompt_tokens.data(), static_cast<std::int32_t>(prompt_tokens.size()), false, true);
        }
        if (prompt_token_count > 0 && llama_vocab_get_add_bos(vocab)) {
            const llama_token bos = llama_vocab_bos(vocab);
            if (bos != LLAMA_TOKEN_NULL && prompt_tokens.front() != bos) {
                prompt_tokens.insert(prompt_tokens.begin(), bos);
                ++prompt_token_count;
            }
        }
        if (prompt_token_count <= 0 ||
            static_cast<std::uint64_t>(prompt_token_count) + max_tokens > session.context_tokens) {
            std::ostringstream message;
            message << "حجم Prompt (" << prompt_token_count
                    << " رمزاً) مع الإخراج المطلوب يتجاوز سياق النموذج ("
                    << session.context_tokens << "). قلّل النص أو عدد رموز الإخراج.";
            set_error(message.str());
            return -4;
        }

        SamplerGuard sampler(llama_sampler_chain_init(llama_sampler_chain_default_params()));
        if (sampler.sampler == nullptr) {
            set_error("تعذر إنشاء سلسلة أخذ عينات التوليد.");
            return -5;
        }
        auto add_sampler = [&](llama_sampler *step) {
            if (step == nullptr) {
                return false;
            }
            llama_sampler_chain_add(sampler.sampler, step);
            return true;
        };
        const std::uint32_t effective_seed = seed == 0 ? LLAMA_DEFAULT_SEED : seed;
        if (!add_sampler(llama_sampler_init_top_k(static_cast<std::int32_t>(top_k))) ||
            !add_sampler(llama_sampler_init_top_p(top_p, 1)) ||
            !add_sampler(llama_sampler_init_temp(temperature)) ||
            !add_sampler(llama_sampler_init_dist(effective_seed))) {
            set_error("تعذر إعداد إحدى مراحل أخذ العينات.");
            return -5;
        }

        BatchGuard batch(llama_batch_init(static_cast<std::int32_t>(kPromptBatchTokens), 0, 1));
        bool batch_ready = batch.batch.token != nullptr && batch.batch.pos != nullptr &&
            batch.batch.n_seq_id != nullptr && batch.batch.seq_id != nullptr &&
            batch.batch.logits != nullptr;
        if (batch_ready) {
            for (std::uint32_t index = 0; index < kPromptBatchTokens; ++index) {
                if (batch.batch.seq_id[index] == nullptr) {
                    batch_ready = false;
                    break;
                }
            }
        }
        if (!batch_ready) {
            set_error("تعذر حجز مساحة معالجة Prompt.");
            return -5;
        }

        for (std::int32_t offset = 0; offset < prompt_token_count;) {
            if (cancellation_requested.load(std::memory_order_acquire)) {
                set_error("أوقف المستخدم عملية التوليد.");
                return 2;
            }
            const auto count = std::min<std::int32_t>(
                static_cast<std::int32_t>(kPromptBatchTokens), prompt_token_count - offset);
            batch.batch.n_tokens = count;
            for (std::int32_t i = 0; i < count; ++i) {
                const auto absolute_index = offset + i;
                batch.batch.token[i] = prompt_tokens[static_cast<std::size_t>(absolute_index)];
                batch.batch.pos[i] = absolute_index;
                batch.batch.n_seq_id[i] = 1;
                batch.batch.seq_id[i][0] = 0;
                batch.batch.logits[i] = absolute_index == prompt_token_count - 1 ? 1 : 0;
            }
            const std::int32_t decode_status = llama_decode(session.context, batch.batch);
            if (decode_status != 0) {
                if (cancellation_requested.load(std::memory_order_acquire)) {
                    set_error("أوقف المستخدم معالجة Prompt.");
                    return 2;
                }
                set_error("فشلت معالجة Prompt داخل llama.cpp.");
                return -6;
            }
            offset += count;
        }

        std::uint32_t emitted_tokens = 0;
        std::vector<char> piece_buffer(256U);
        for (std::uint32_t index = 0; index < max_tokens; ++index) {
            if (cancellation_requested.load(std::memory_order_acquire)) {
                if (generated_tokens != nullptr) {
                    *generated_tokens = emitted_tokens;
                }
                set_error("أوقف المستخدم عملية التوليد.");
                return 2;
            }

            const llama_token token = llama_sampler_sample(sampler.sampler, session.context, -1);
            if (token == LLAMA_TOKEN_NULL) {
                set_error("لم يُنتج Sampler رمزاً صالحاً.");
                return -7;
            }
            if (llama_vocab_is_eog(vocab, token)) {
                break;
            }

            std::int32_t piece_size = llama_token_to_piece(
                vocab, token, piece_buffer.data(), static_cast<std::int32_t>(piece_buffer.size()), 0, false);
            if (piece_size < 0) {
                if (piece_size == std::numeric_limits<std::int32_t>::min()) {
                    set_error("تعذر تحديد طول Token الناتج.");
                    return -7;
                }
                piece_buffer.resize(static_cast<std::size_t>(-piece_size));
                piece_size = llama_token_to_piece(
                    vocab, token, piece_buffer.data(), static_cast<std::int32_t>(piece_buffer.size()), 0, false);
            }
            if (piece_size < 0) {
                set_error("تعذر تحويل Token إلى نص.");
                return -7;
            }
            ++emitted_tokens;
            if (piece_size > 0 && on_token_piece(
                    piece_buffer.data(), static_cast<std::size_t>(piece_size), emitted_tokens, user_data) == 0) {
                set_error("توقف مستهلك تدفق التوليد عن استقبال النص.");
                if (generated_tokens != nullptr) {
                    *generated_tokens = emitted_tokens;
                }
                return -8;
            }
            if (generated_tokens != nullptr) {
                *generated_tokens = emitted_tokens;
            }

            if (index + 1U < max_tokens) {
                batch.batch.n_tokens = 1;
                batch.batch.token[0] = token;
                batch.batch.pos[0] = prompt_token_count + static_cast<std::int32_t>(index);
                batch.batch.n_seq_id[0] = 1;
                batch.batch.seq_id[0][0] = 0;
                batch.batch.logits[0] = 1;
                const std::int32_t decode_status = llama_decode(session.context, batch.batch);
                if (decode_status != 0) {
                    if (cancellation_requested.load(std::memory_order_acquire)) {
                        set_error("أوقف المستخدم عملية التوليد أثناء حساب Token.");
                        return 2;
                    }
                    set_error("فشلت معالجة Token جديد داخل llama.cpp.");
                    return -6;
                }
            }
        }

        if (cancellation_requested.load(std::memory_order_acquire)) {
            set_error("أوقف المستخدم عملية التوليد.");
            return 2;
        }
        if (emitted_tokens == 0) {
            set_error("انتهى النموذج دون إنتاج نص قابل للعرض.");
            return -7;
        }
        inference_verified.store(true, std::memory_order_release);
        last_error.clear();
        return 1;
    } catch (const std::exception &error) {
        try {
            set_error(std::string("استثناء أثناء توليد النص: ") + error.what());
        } catch (...) {
            set_error("نفدت الذاكرة أثناء تجهيز رسالة خطأ التوليد.");
        }
        return -9;
    } catch (...) {
        set_error("حدث خطأ غير معروف أثناء توليد النص.");
        return -9;
    }
}

NEXUS_EXPORT std::int32_t nexus_llama_unload_model() noexcept {
    try {
        std::lock_guard<std::mutex> lock(session_mutex);
        release_session_locked();
        last_error.clear();
        return 1;
    } catch (...) {
        set_error("تعذر تفريغ جلسة llama.cpp.");
        return 0;
    }
}

NEXUS_EXPORT std::int32_t nexus_llama_is_model_loaded() noexcept {
    try {
        std::lock_guard<std::mutex> lock(session_mutex);
        return session.model != nullptr && session.context != nullptr ? 1 : 0;
    } catch (...) {
        set_error("تعذر قراءة حالة جلسة llama.cpp.");
        return 0;
    }
}

NEXUS_EXPORT std::uint32_t nexus_llama_loaded_context_tokens() noexcept {
    try {
        std::lock_guard<std::mutex> lock(session_mutex);
        return session.context_tokens;
    } catch (...) {
        set_error("تعذر قراءة حجم سياق llama.cpp.");
        return 0;
    }
}

// The message remains valid until the next NEXUS call on the same thread.
NEXUS_EXPORT const char *nexus_llama_last_error() noexcept {
    return last_error.c_str();
}

}  // extern "C"
