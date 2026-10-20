#pragma once
#include "Engine.hpp"
#include "Personalization.hpp"
namespace kb {
// Versioned little-endian boundary format. UTF-8 uses explicit lengths (including
// embedded NUL); framework string encodings and C++ object layouts never leak.
std::vector<std::byte> encodeDecodeOutput(const DecodeOutput&);
std::vector<std::byte> encodePersonalization(const PersonalizationSnapshot&);
PersonalizationSnapshot decodePersonalization(std::span<const std::byte>);
}
