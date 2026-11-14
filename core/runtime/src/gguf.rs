//! Bounded GGUF header and metadata inspection.
//!
//! This module reads the fixed header and metadata directory only. It does not
//! inspect tensor payloads, validate offsets, or load model weights.
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

const HEADER_BYTES: u64 = 24;
const MAX_METADATA_ENTRIES: u64 = 100_000;
const MAX_TENSORS: u64 = 1_000_000;
const MAX_KEY_BYTES: u64 = 4 * 1024;
const MAX_SELECTED_STRING_BYTES: u64 = 64 * 1024;
const MAX_ARRAY_ITEMS: u64 = 2_000_000;

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct GgufMetadata {
    pub architecture: Option<String>,
    pub model_name: Option<String>,
    pub tokenizer_model: Option<String>,
    pub context_length: Option<u64>,
    pub block_count: Option<u64>,
    pub embedding_length: Option<u64>,
    pub attention_head_count: Option<u64>,
    pub attention_head_count_kv: Option<u64>,
    pub attention_key_length: Option<u64>,
    pub attention_value_length: Option<u64>,
    pub file_type: Option<u64>,
    pub parameter_count: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GgufInspection {
    pub file_name: String,
    pub size_bytes: u64,
    pub format_version: u32,
    pub tensor_count: u64,
    pub metadata_count: u64,
    pub metadata: GgufMetadata,
}

pub fn inspect_gguf_file(path: &str) -> Result<GgufInspection, String> {
    let file_path = Path::new(path);
    let extension = file_path.extension().and_then(|value| value.to_str()).unwrap_or("");
    if !extension.eq_ignore_ascii_case("gguf") {
        return Err("امتداد الملف ليس GGUF".to_owned());
    }

    let mut file = File::open(file_path).map_err(|error| format!("تعذر فتح الملف: {error}"))?;
    let size_bytes = file.metadata().map_err(|error| format!("تعذر قراءة معلومات الملف: {error}"))?.len();
    if size_bytes < HEADER_BYTES {
        return Err("الملف أصغر من ترويسة GGUF الأساسية".to_owned());
    }

    let mut magic = [0_u8; 4];
    file.read_exact(&mut magic).map_err(io_error)?;
    if &magic != b"GGUF" {
        return Err("توقيع الملف غير صحيح؛ لم يتم العثور على GGUF".to_owned());
    }
    let format_version = read_u32(&mut file, size_bytes)?;
    let tensor_count = read_u64(&mut file, size_bytes)?;
    let metadata_count = read_u64(&mut file, size_bytes)?;

    if !(2..=3).contains(&format_version) {
        return Err(format!("إصدار GGUF غير مدعوم للفحص الأولي: {format_version}"));
    }
    if tensor_count == 0 || tensor_count > MAX_TENSORS {
        return Err("عدد الموترات خارج النطاق المتوقع لملف نموذج".to_owned());
    }
    if metadata_count == 0 || metadata_count > MAX_METADATA_ENTRIES {
        return Err("عدد عناصر البيانات الوصفية خارج النطاق الآمن للفحص".to_owned());
    }

    let mut metadata = GgufMetadata::default();
    let mut architecture_specific: Vec<(String, u64)> = Vec::new();

    for _ in 0..metadata_count {
        let key = read_string(&mut file, size_bytes, MAX_KEY_BYTES)?;
        let value_type = read_u32(&mut file, size_bytes)?;
        match key.as_str() {
            "general.architecture" => {
                metadata.architecture = Some(read_string_value(&mut file, size_bytes, value_type)?);
            }
            "general.name" => {
                metadata.model_name = Some(read_string_value(&mut file, size_bytes, value_type)?);
            }
            "tokenizer.ggml.model" => {
                metadata.tokenizer_model = Some(read_string_value(&mut file, size_bytes, value_type)?);
            }
            "general.file_type" => {
                metadata.file_type = Some(read_unsigned_value(&mut file, size_bytes, value_type)?);
            }
            "general.parameter_count" => {
                metadata.parameter_count = Some(read_unsigned_value(&mut file, size_bytes, value_type)?);
            }
            _ if key.ends_with(".context_length")
                || key.ends_with(".block_count")
                || key.ends_with(".embedding_length")
                || key.ends_with(".attention.head_count")
                || key.ends_with(".attention.head_count_kv")
                || key.ends_with(".attention.key_length")
                || key.ends_with(".attention.value_length") =>
            {
                let value = read_unsigned_value(&mut file, size_bytes, value_type)?;
                architecture_specific.push((key, value));
            }
            _ => skip_value(&mut file, size_bytes, value_type)?,
        }
    }

    if let Some(architecture) = metadata.architecture.as_deref() {
        let prefix = format!("{architecture}.");
        for (key, value) in architecture_specific {
            if let Some(field) = key.strip_prefix(&prefix) {
                match field {
                    "context_length" => metadata.context_length = Some(value),
                    "block_count" => metadata.block_count = Some(value),
                    "embedding_length" => metadata.embedding_length = Some(value),
                    "attention.head_count" => metadata.attention_head_count = Some(value),
                    "attention.head_count_kv" => metadata.attention_head_count_kv = Some(value),
                    "attention.key_length" => metadata.attention_key_length = Some(value),
                    "attention.value_length" => metadata.attention_value_length = Some(value),
                    _ => {}
                }
            }
        }
    }

    Ok(GgufInspection {
        file_name: file_path.file_name().and_then(|value| value.to_str()).unwrap_or("model.gguf").to_owned(),
        size_bytes,
        format_version,
        tensor_count,
        metadata_count,
        metadata,
    })
}

fn io_error(error: std::io::Error) -> String {
    format!("تعذر قراءة بيانات GGUF: {error}")
}

fn ensure_remaining(file: &mut File, file_size: u64, bytes: u64) -> Result<(), String> {
    let position = file.stream_position().map_err(io_error)?;
    let end = position.checked_add(bytes).ok_or_else(|| "تجاوز طول بيانات GGUF النطاق".to_owned())?;
    if end > file_size {
        return Err("بيانات GGUF الوصفية مبتورة أو تتجاوز حجم الملف".to_owned());
    }
    Ok(())
}

fn read_u32(file: &mut File, file_size: u64) -> Result<u32, String> {
    ensure_remaining(file, file_size, 4)?;
    let mut bytes = [0_u8; 4];
    file.read_exact(&mut bytes).map_err(io_error)?;
    Ok(u32::from_le_bytes(bytes))
}

fn read_u64(file: &mut File, file_size: u64) -> Result<u64, String> {
    ensure_remaining(file, file_size, 8)?;
    let mut bytes = [0_u8; 8];
    file.read_exact(&mut bytes).map_err(io_error)?;
    Ok(u64::from_le_bytes(bytes))
}

fn read_string(file: &mut File, file_size: u64, max_len: u64) -> Result<String, String> {
    let length = read_u64(file, file_size)?;
    if length > max_len {
        return Err("حجم نص البيانات الوصفية يتجاوز الحد الآمن".to_owned());
    }
    ensure_remaining(file, file_size, length)?;
    let length_usize = usize::try_from(length).map_err(|_| "طول النص غير مدعوم على هذا الجهاز".to_owned())?;
    let mut bytes = vec![0_u8; length_usize];
    file.read_exact(&mut bytes).map_err(io_error)?;
    String::from_utf8(bytes).map_err(|_| "نص البيانات الوصفية ليس UTF-8 صالحاً".to_owned())
}

fn read_string_value(file: &mut File, file_size: u64, value_type: u32) -> Result<String, String> {
    if value_type != 8 {
        return Err("نوع قيمة نصية في GGUF غير متوافق".to_owned());
    }
    read_string(file, file_size, MAX_SELECTED_STRING_BYTES)
}

fn read_unsigned_value(file: &mut File, file_size: u64, value_type: u32) -> Result<u64, String> {
    match value_type {
        0 => {
            ensure_remaining(file, file_size, 1)?;
            let mut value = [0_u8; 1];
            file.read_exact(&mut value).map_err(io_error)?;
            Ok(u64::from(value[0]))
        }
        2 => {
            ensure_remaining(file, file_size, 2)?;
            let mut value = [0_u8; 2];
            file.read_exact(&mut value).map_err(io_error)?;
            Ok(u64::from(u16::from_le_bytes(value)))
        }
        4 => Ok(u64::from(read_u32(file, file_size)?)),
        10 => read_u64(file, file_size),
        _ => Err("نوع قيمة رقمية في GGUF غير متوافق".to_owned()),
    }
}

fn skip_value(file: &mut File, file_size: u64, value_type: u32) -> Result<(), String> {
    let fixed_size = match value_type {
        0 | 1 | 7 => Some(1_u64),
        2 | 3 => Some(2),
        4..=6 => Some(4),
        10..=12 => Some(8),
        8 => {
            skip_string(file, file_size)?;
            None
        }
        9 => {
            let element_type = read_u32(file, file_size)?;
            let count = read_u64(file, file_size)?;
            if count > MAX_ARRAY_ITEMS {
                return Err("عدد عناصر مصفوفة GGUF يتجاوز الحد الآمن".to_owned());
            }
            if let Some(size) = primitive_size(element_type) {
                let total = size.checked_mul(count).ok_or_else(|| "حجم مصفوفة GGUF تجاوز النطاق".to_owned())?;
                ensure_remaining(file, file_size, total)?;
                file.seek(SeekFrom::Current(i64::try_from(total).map_err(|_| "حجم مصفوفة GGUF غير مدعوم".to_owned())?)).map_err(io_error)?;
            } else if element_type == 8 {
                for _ in 0..count {
                    skip_string(file, file_size)?;
                }
            } else {
                return Err("نوع عناصر مصفوفة GGUF غير مدعوم".to_owned());
            }
            None
        }
        _ => return Err(format!("نوع بيانات GGUF غير معروف: {value_type}")),
    };
    if let Some(size) = fixed_size {
        ensure_remaining(file, file_size, size)?;
        let offset = i64::try_from(size).map_err(|_| "حجم قيمة GGUF غير مدعوم".to_owned())?;
        file.seek(SeekFrom::Current(offset)).map_err(io_error)?;
    }
    Ok(())
}

fn primitive_size(value_type: u32) -> Option<u64> {
    match value_type {
        0 | 1 | 7 => Some(1),
        2 | 3 => Some(2),
        4..=6 => Some(4),
        10..=12 => Some(8),
        _ => None,
    }
}

fn skip_string(file: &mut File, file_size: u64) -> Result<(), String> {
    let length = read_u64(file, file_size)?;
    ensure_remaining(file, file_size, length)?;
    let offset = i64::try_from(length).map_err(|_| "نص GGUF كبير جداً لتجاوزه بأمان".to_owned())?;
    file.seek(SeekFrom::Current(offset)).map_err(io_error)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_file(name: &str, bytes: &[u8]) -> String {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let path = std::env::temp_dir().join(format!("nexus-{stamp}-{name}"));
        fs::write(&path, bytes).unwrap();
        path.to_string_lossy().into_owned()
    }

    fn push_string(bytes: &mut Vec<u8>, value: &str) {
        bytes.extend_from_slice(&(value.len() as u64).to_le_bytes());
        bytes.extend_from_slice(value.as_bytes());
    }

    fn push_string_entry(bytes: &mut Vec<u8>, key: &str, value: &str) {
        push_string(bytes, key);
        bytes.extend_from_slice(&8_u32.to_le_bytes());
        push_string(bytes, value);
    }

    fn push_u32_entry(bytes: &mut Vec<u8>, key: &str, value: u32) {
        push_string(bytes, key);
        bytes.extend_from_slice(&4_u32.to_le_bytes());
        bytes.extend_from_slice(&value.to_le_bytes());
    }

    fn test_header(metadata_count: u64) -> Vec<u8> {
        let mut bytes = Vec::from(&b"GGUF"[..]);
        bytes.extend_from_slice(&3_u32.to_le_bytes());
        bytes.extend_from_slice(&12_u64.to_le_bytes());
        bytes.extend_from_slice(&metadata_count.to_le_bytes());
        bytes
    }

    #[test]
    fn reads_model_architecture_and_runtime_dimensions() {
        let mut bytes = test_header(7);
        push_string_entry(&mut bytes, "general.architecture", "llama");
        push_string_entry(&mut bytes, "general.name", "NEXUS test model");
        push_string_entry(&mut bytes, "tokenizer.ggml.model", "llama");
        push_u32_entry(&mut bytes, "general.file_type", 15);
        push_u32_entry(&mut bytes, "general.parameter_count", 3_000_000_000_u32);
        push_u32_entry(&mut bytes, "llama.context_length", 4096);
        push_u32_entry(&mut bytes, "llama.block_count", 32);
        let path = temp_file("metadata.gguf", &bytes);
        let result = inspect_gguf_file(&path).unwrap();
        assert_eq!(result.metadata.architecture.as_deref(), Some("llama"));
        assert_eq!(result.metadata.model_name.as_deref(), Some("NEXUS test model"));
        assert_eq!(result.metadata.context_length, Some(4096));
        assert_eq!(result.metadata.block_count, Some(32));
        assert_eq!(result.metadata.file_type, Some(15));
        assert_eq!(result.metadata.parameter_count, Some(3_000_000_000));
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn reads_architecture_specific_kv_cache_dimensions() {
        let mut bytes = test_header(7);
        push_string_entry(&mut bytes, "general.architecture", "llama");
        push_u32_entry(&mut bytes, "llama.attention.head_count", 32);
        push_u32_entry(&mut bytes, "llama.attention.head_count_kv", 8);
        push_u32_entry(&mut bytes, "llama.attention.key_length", 128);
        push_u32_entry(&mut bytes, "llama.attention.value_length", 128);
        push_u32_entry(&mut bytes, "llama.block_count", 32);
        push_u32_entry(&mut bytes, "llama.embedding_length", 4096);
        let path = temp_file("kv-metadata.gguf", &bytes);
        let result = inspect_gguf_file(&path).unwrap();
        assert_eq!(result.metadata.attention_head_count, Some(32));
        assert_eq!(result.metadata.attention_head_count_kv, Some(8));
        assert_eq!(result.metadata.attention_key_length, Some(128));
        assert_eq!(result.metadata.attention_value_length, Some(128));
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn safely_skips_string_arrays_before_reading_following_metadata() {
        let mut bytes = test_header(3);
        push_string(&mut bytes, "tokenizer.ggml.tokens");
        bytes.extend_from_slice(&9_u32.to_le_bytes());
        bytes.extend_from_slice(&8_u32.to_le_bytes());
        bytes.extend_from_slice(&2_u64.to_le_bytes());
        push_string(&mut bytes, "one");
        push_string(&mut bytes, "two");
        push_u32_entry(&mut bytes, "llama.context_length", 2048);
        push_string_entry(&mut bytes, "general.architecture", "llama");
        let path = temp_file("array.gguf", &bytes);
        let result = inspect_gguf_file(&path).unwrap();
        assert_eq!(result.metadata.context_length, Some(2048));
        assert_eq!(result.metadata.architecture.as_deref(), Some("llama"));
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn rejects_wrong_magic_extension_truncated_and_unsupported_version() {
        let wrong_magic = temp_file("wrong.gguf", b"NOPE00000000000000000000");
        assert!(inspect_gguf_file(&wrong_magic).unwrap_err().contains("توقيع"));
        fs::remove_file(wrong_magic).unwrap();

        let wrong_extension = temp_file("model.bin", b"GGUF00000000000000000000");
        assert!(inspect_gguf_file(&wrong_extension).unwrap_err().contains("امتداد"));
        fs::remove_file(wrong_extension).unwrap();

        let short = temp_file("short.gguf", b"GGUF");
        assert!(inspect_gguf_file(&short).unwrap_err().contains("أصغر"));
        fs::remove_file(short).unwrap();

        let mut bytes = test_header(1);
        bytes[4..8].copy_from_slice(&99_u32.to_le_bytes());
        let unsupported = temp_file("version.gguf", &bytes);
        assert!(inspect_gguf_file(&unsupported).unwrap_err().contains("إصدار"));
        fs::remove_file(unsupported).unwrap();
    }

    #[test]
    fn rejects_oversized_metadata_key_without_allocating_it() {
        let mut bytes = test_header(1);
        bytes.extend_from_slice(&(MAX_KEY_BYTES + 1).to_le_bytes());
        let path = temp_file("oversized-key.gguf", &bytes);
        assert!(inspect_gguf_file(&path).unwrap_err().contains("الحد الآمن"));
        fs::remove_file(path).unwrap();
    }
}
