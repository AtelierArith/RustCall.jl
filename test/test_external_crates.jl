# Integration tests for popular external Rust crates
# Phase 3: These tests require network access to download crates on first run

using RustCall
using Test

# Control which tests run via environment variables
const RUN_SERDE_TESTS = get(ENV, "RUSTCALL_RUN_SERDE_TESTS", "true") == "true"
const RUN_REGEX_TESTS = get(ENV, "RUSTCALL_RUN_REGEX_TESTS", "true") == "true"
const RUN_UUID_TESTS = get(ENV, "RUSTCALL_RUN_UUID_TESTS", "true") == "true"

@testset "External Crate Integration Tests" begin

    # ============================================================================
    # serde/serde_json - JSON Serialization (Priority 1)
    # ============================================================================
    if RUN_SERDE_TESTS
        @testset "serde_json Integration" begin
            @testset "JSON string length" begin
                rust"""
                //! ```cargo
                //! [dependencies]
                //! serde = { version = "1.0", features = ["derive"] }
                //! serde_json = "1.0"
                //! ```

                use serde::{Serialize, Deserialize};
                use serde_json;

                #[derive(Serialize, Deserialize)]
                struct Point {
                    x: f64,
                    y: f64,
                }

                #[no_mangle]
                pub extern "C" fn json_serialize_point(x: f64, y: f64) -> usize {
                    let point = Point { x, y };
                    let json = serde_json::to_string(&point).unwrap_or_default();
                    json.len()
                }
                """

                # Serialize a point and get JSON length
                # Expected: {"x":1.0,"y":2.0} = 17 chars (may vary by formatting)
                result = @rust json_serialize_point(1.0, 2.0)::UInt
                @test result > 10  # JSON should have reasonable length
            end

            @testset "JSON parsing validation" begin
                rust"""
                //! ```cargo
                //! [dependencies]
                //! serde_json = "1.0"
                //! ```

                use serde_json::Value;

                #[no_mangle]
                pub extern "C" fn json_is_valid_object(ptr: *const u8, len: usize) -> bool {
                    let slice = unsafe { std::slice::from_raw_parts(ptr, len) };
                    let s = match std::str::from_utf8(slice) {
                        Ok(s) => s,
                        Err(_) => return false,
                    };
                    match serde_json::from_str::<Value>(s) {
                        Ok(Value::Object(_)) => true,
                        _ => false,
                    }
                }
                """

                # Valid JSON object
                valid_json = """{"name": "test", "value": 42}"""
                result = @rust json_is_valid_object(pointer(Vector{UInt8}(valid_json)), length(valid_json))::Bool
                @test result == true

                # Invalid JSON
                invalid_json = "not json"
                result = @rust json_is_valid_object(pointer(Vector{UInt8}(invalid_json)), length(invalid_json))::Bool
                @test result == false

                # Valid JSON but not an object
                json_array = "[1, 2, 3]"
                result = @rust json_is_valid_object(pointer(Vector{UInt8}(json_array)), length(json_array))::Bool
                @test result == false
            end
        end
    else
        @testset "serde_json Integration (skipped)" begin
            @test_skip "Set RUSTCALL_RUN_SERDE_TESTS=true to run serde tests"
        end
    end

    # ============================================================================
    # regex - Regular Expressions (Priority 3)
    # ============================================================================
    if RUN_REGEX_TESTS
        @testset "regex Integration" begin
            @testset "Pattern matching" begin
                rust"""
                //! ```cargo
                //! [dependencies]
                //! regex = "1"
                //! ```

                use regex::Regex;

                #[no_mangle]
                pub extern "C" fn regex_count_matches(
                    text_ptr: *const u8,
                    text_len: usize,
                    pattern_ptr: *const u8,
                    pattern_len: usize
                ) -> i32 {
                    let text_slice = unsafe { std::slice::from_raw_parts(text_ptr, text_len) };
                    let pattern_slice = unsafe { std::slice::from_raw_parts(pattern_ptr, pattern_len) };

                    let text = match std::str::from_utf8(text_slice) {
                        Ok(s) => s,
                        Err(_) => return -1,
                    };
                    let pattern = match std::str::from_utf8(pattern_slice) {
                        Ok(s) => s,
                        Err(_) => return -1,
                    };

                    match Regex::new(pattern) {
                        Ok(re) => re.find_iter(text).count() as i32,
                        Err(_) => -1,
                    }
                }
                """

                # Count word occurrences
                text = "the quick brown fox jumps over the lazy dog"
                pattern = "the"
                result = @rust regex_count_matches(
                    pointer(Vector{UInt8}(text)), length(text),
                    pointer(Vector{UInt8}(pattern)), length(pattern)
                )::Int32
                @test result == 2

                # Count digits
                text2 = "abc123def456ghi789"
                pattern2 = "[0-9]+"
                result2 = @rust regex_count_matches(
                    pointer(Vector{UInt8}(text2)), length(text2),
                    pointer(Vector{UInt8}(pattern2)), length(pattern2)
                )::Int32
                @test result2 == 3
            end

            @testset "Email validation" begin
                rust"""
                //! ```cargo
                //! [dependencies]
                //! regex = "1"
                //! ```

                use regex::Regex;

                #[no_mangle]
                pub extern "C" fn regex_is_valid_email(ptr: *const u8, len: usize) -> bool {
                    let slice = unsafe { std::slice::from_raw_parts(ptr, len) };
                    let s = match std::str::from_utf8(slice) {
                        Ok(s) => s,
                        Err(_) => return false,
                    };

                    // Simple email pattern
                    let re = Regex::new(r"^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$").unwrap();
                    re.is_match(s)
                }
                """

                valid_email = "test@example.com"
                result = @rust regex_is_valid_email(pointer(Vector{UInt8}(valid_email)), length(valid_email))::Bool
                @test result == true

                invalid_email = "not-an-email"
                result = @rust regex_is_valid_email(pointer(Vector{UInt8}(invalid_email)), length(invalid_email))::Bool
                @test result == false
            end
        end
    else
        @testset "regex Integration (skipped)" begin
            @test_skip "Set RUSTCALL_RUN_REGEX_TESTS=true to run regex tests"
        end
    end

    # ============================================================================
    # uuid - UUID Generation (Priority 3)
    # ============================================================================
    if RUN_UUID_TESTS
        @testset "uuid Integration" begin
            @testset "UUID generation" begin
                rust"""
                //! ```cargo
                //! [dependencies]
                //! uuid = { version = "1", features = ["v4"] }
                //! ```

                use uuid::Uuid;

                #[no_mangle]
                pub extern "C" fn uuid_generate_v4_length() -> usize {
                    let uuid = Uuid::new_v4();
                    uuid.to_string().len()
                }

                #[no_mangle]
                pub extern "C" fn uuid_is_valid(ptr: *const u8, len: usize) -> bool {
                    let slice = unsafe { std::slice::from_raw_parts(ptr, len) };
                    let s = match std::str::from_utf8(slice) {
                        Ok(s) => s,
                        Err(_) => return false,
                    };
                    Uuid::parse_str(s).is_ok()
                }
                """

                # UUID v4 strings are always 36 characters (8-4-4-4-12 format)
                result = @rust uuid_generate_v4_length()::UInt
                @test result == 36

                # Valid UUID
                valid_uuid = "550e8400-e29b-41d4-a716-446655440000"
                result = @rust uuid_is_valid(pointer(Vector{UInt8}(valid_uuid)), length(valid_uuid))::Bool
                @test result == true

                # Invalid UUID
                invalid_uuid = "not-a-uuid"
                result = @rust uuid_is_valid(pointer(Vector{UInt8}(invalid_uuid)), length(invalid_uuid))::Bool
                @test result == false
            end
        end
    else
        @testset "uuid Integration (skipped)" begin
            @test_skip "Set RUSTCALL_RUN_UUID_TESTS=true to run uuid tests"
        end
    end

    # ============================================================================
    # chrono - Date/Time Handling (Priority 3)
    # ============================================================================
    @testset "chrono Integration" begin
        rust"""
        //! ```cargo
        //! [dependencies]
        //! chrono = "0.4"
        //! ```

        use chrono::{NaiveDate, Datelike};

        #[no_mangle]
        pub extern "C" fn chrono_days_in_month(year: i32, month: u32) -> u32 {
            match NaiveDate::from_ymd_opt(year, month, 1) {
                Some(date) => {
                    // Get the last day of the month
                    let next_month = if month == 12 { 1 } else { month + 1 };
                    let next_year = if month == 12 { year + 1 } else { year };
                    match NaiveDate::from_ymd_opt(next_year, next_month, 1) {
                        Some(next) => (next - date).num_days() as u32,
                        None => 0,
                    }
                },
                None => 0,
            }
        }

        #[no_mangle]
        pub extern "C" fn chrono_is_leap_year(year: i32) -> bool {
            match NaiveDate::from_ymd_opt(year, 2, 29) {
                Some(_) => true,
                None => false,
            }
        }
        """

        # Test days in month
        @test @rust(chrono_days_in_month(Int32(2024), UInt32(1))::UInt32) == 31  # January
        @test @rust(chrono_days_in_month(Int32(2024), UInt32(2))::UInt32) == 29  # February (leap year)
        @test @rust(chrono_days_in_month(Int32(2023), UInt32(2))::UInt32) == 28  # February (non-leap year)
        @test @rust(chrono_days_in_month(Int32(2024), UInt32(4))::UInt32) == 30  # April

        # Test leap year detection
        @test @rust(chrono_is_leap_year(Int32(2024))::Bool) == true
        @test @rust(chrono_is_leap_year(Int32(2023))::Bool) == false
        @test @rust(chrono_is_leap_year(Int32(2000))::Bool) == true
        @test @rust(chrono_is_leap_year(Int32(1900))::Bool) == false
    end

end
