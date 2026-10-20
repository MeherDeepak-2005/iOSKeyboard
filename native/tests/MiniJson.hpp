#pragma once
// Test-only JSON reader for the shared-engine fixtures (objects, arrays, strings with
// \uXXXX escapes, numbers, true/false/null). Not a general or hardened parser.
#include <cstdlib>
#include <map>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <variant>
#include <vector>
namespace json {
struct Value;
using Array = std::vector<Value>;
using Object = std::map<std::string, Value, std::less<>>;
struct Value {
    std::variant<std::nullptr_t, bool, double, std::string, std::shared_ptr<Array>, std::shared_ptr<Object>> data;
    bool null() const { return std::holds_alternative<std::nullptr_t>(data); }
    double number() const { return std::get<double>(data); }
    const std::string& text() const { return std::get<std::string>(data); }
    const Array& array() const { return *std::get<std::shared_ptr<Array>>(data); }
    const Value& operator[](std::string_view key) const {
        const auto& object = *std::get<std::shared_ptr<Object>>(data);
        auto found = object.find(key); if (found == object.end()) throw std::out_of_range(std::string(key)); return found->second;
    }
};
class Parser {
    std::string_view s; std::size_t i = 0;
    void space() { while (i < s.size() && (s[i] == ' ' || s[i] == '\n' || s[i] == '\r' || s[i] == '\t')) ++i; }
    void expect(char c) { space(); if (i >= s.size() || s[i] != c) throw std::invalid_argument("bad json"); ++i; }
    static void utf8(std::string& out, std::uint32_t c) {
        if (c < 0x80) out += char(c);
        else if (c < 0x800) { out += char(0xc0 | c >> 6); out += char(0x80 | (c & 63)); }
        else if (c < 0x10000) { out += char(0xe0 | c >> 12); out += char(0x80 | (c >> 6 & 63)); out += char(0x80 | (c & 63)); }
        else { out += char(0xf0 | c >> 18); out += char(0x80 | (c >> 12 & 63)); out += char(0x80 | (c >> 6 & 63)); out += char(0x80 | (c & 63)); }
    }
    std::uint32_t hex4() { auto v = std::uint32_t(std::stoul(std::string(s.substr(i, 4)), nullptr, 16)); i += 4; return v; }
    std::string string() {
        expect('"'); std::string out;
        while (s.at(i) != '"') {
            if (s[i] != '\\') { out += s[i++]; continue; }
            switch (s.at(++i)) {
            case 'u': { ++i; auto c = hex4(); if (c >= 0xd800 && c < 0xdc00) { i += 2; c = 0x10000 + ((c - 0xd800) << 10) + (hex4() - 0xdc00); } utf8(out, c); continue; }
            case 'n': out += '\n'; break; case 't': out += '\t'; break; case 'r': out += '\r'; break;
            case 'b': out += '\b'; break; case 'f': out += '\f'; break; default: out += s[i];
            }
            ++i;
        }
        ++i; return out;
    }
public:
    explicit Parser(std::string_view text) : s(text) {}
    Value value() {
        space();
        switch (s.at(i)) {
        case '{': {
            ++i; auto object = std::make_shared<Object>(); space();
            if (s.at(i) == '}') { ++i; return {object}; }
            for (;;) { auto key = string(); expect(':'); (*object)[key] = value(); space(); if (s.at(i++) == '}') return {object}; }
        }
        case '[': {
            ++i; auto array = std::make_shared<Array>(); space();
            if (s.at(i) == ']') { ++i; return {array}; }
            for (;;) { array->push_back(value()); space(); if (s.at(i++) == ']') return {array}; }
        }
        case '"': return {string()};
        case 't': i += 4; return {true};
        case 'f': i += 5; return {false};
        case 'n': i += 4; return {nullptr};
        default: { const char* begin = s.data() + i; char* end = nullptr; double v = std::strtod(begin, &end); i += std::size_t(end - begin); return {v}; }
        }
    }
};
inline Value parse(std::string_view text) { return Parser(text).value(); }
}
