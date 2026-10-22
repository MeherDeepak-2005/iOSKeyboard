#include "../include/EngineWire.hpp"
#include <bit>
#include <limits>
#include <stdexcept>
namespace kb {
namespace {
struct Writer {
    std::vector<std::byte> bytes;
    void u32(std::uint32_t n) { for (int i=0;i<4;++i) bytes.push_back(std::byte(n>>(8*i))); }
    void u64(std::uint64_t n) { for (int i=0;i<8;++i) bytes.push_back(std::byte(n>>(8*i))); }
    void real(double n) { u64(std::bit_cast<std::uint64_t>(n)); }
    void text(std::string_view value) { if(value.size()>=UINT32_MAX)throw std::length_error("wire text too large");u32(std::uint32_t(value.size()));for(unsigned char c:value)bytes.push_back(std::byte(c)); }
    void optional(const std::optional<std::string>& value) { if(value)text(*value);else u32(UINT32_MAX); }
};
struct Reader {
    std::span<const std::byte> bytes;std::size_t at=0;
    std::uint32_t u32(){ if(bytes.size()-at<4)throw std::invalid_argument("truncated wire integer");std::uint32_t n=0;for(int i=0;i<4;++i)n|=std::to_integer<std::uint32_t>(bytes[at++])<<(i*8);return n; }
    std::uint64_t u64(){auto lo=u32();auto hi=u32();return lo|(std::uint64_t(hi)<<32);}
    std::string text(){auto n=u32();if(n>bytes.size()-at)throw std::invalid_argument("truncated wire text");std::string out(reinterpret_cast<const char*>(bytes.data()+at),n);at+=n;if(!validUTF8(out))throw std::invalid_argument("invalid wire UTF-8");return out;}
};
void writeCounts(Writer& w,const std::unordered_map<std::string,std::int64_t>& values){
    CountRows ordered(values.begin(),values.end());std::sort(ordered.begin(),ordered.end(),[](const auto&a,const auto&b){return utf8Less(a.first,b.first);});w.u32(std::uint32_t(ordered.size()));for(const auto&[key,value]:ordered){w.text(key);w.u64(std::uint64_t(value));}
}
void readCounts(Reader& r,std::unordered_map<std::string,std::int64_t>& out,std::size_t cap){
    auto n=r.u32();if(n>cap)throw std::invalid_argument("wire count cap exceeded");
    for(std::size_t i=0;i<n;++i){auto key=r.text();auto value=r.u64();if(key.empty()||key.size()>maxPersonalWordBytes||value==0||value>INT32_MAX||!out.emplace(std::move(key),std::int64_t(value)).second)throw std::invalid_argument("invalid wire count");}
}
void writeTable(Writer&w,const std::unordered_map<std::string,CountRows>& table){
    std::vector<std::string> keys;for(const auto&[key,row]:table){(void)row;keys.push_back(key);}std::sort(keys.begin(),keys.end(),utf8Less);w.u32(std::uint32_t(keys.size()));
    for(const auto&key:keys){w.text(key);std::unordered_map<std::string,std::int64_t> counts(table.at(key).begin(),table.at(key).end());writeCounts(w,counts);}
}
void readTable(Reader&r,std::unordered_map<std::string,CountRows>& table){
    auto n=r.u32();if(n>4000)throw std::invalid_argument("wire context cap exceeded");
    for(std::size_t i=0;i<n;++i){auto context=r.text();std::unordered_map<std::string,std::int64_t> counts;readCounts(r,counts,8000);if(context.size()>maxPersonalContextBytes||table.contains(context))throw std::invalid_argument("invalid wire context");CountRows row(counts.begin(),counts.end());std::sort(row.begin(),row.end(),[](const auto&a,const auto&b){return utf8Less(a.first,b.first);});table.emplace(std::move(context),std::move(row));}
}
}
std::vector<std::byte> encodeDecodeOutput(const DecodeOutput& out){
    Writer w;w.u32(0x3244424b);w.u32(std::uint32_t(out.status));
    const auto&i=out.identity;for(auto value:{i.fieldRevision,i.documentRevision,i.wordSessionID,i.generation,i.layoutRevision,i.vocabularyEpoch,i.personalizationEpoch})w.u64(value);
    w.u32(std::uint32_t(out.suggestions.size()));for(const auto&s:out.suggestions)w.text(s);
    w.optional(out.correction.word);w.real(out.correction.margin);w.u32(std::uint32_t(out.candidates.size()));
    for(const auto&c:out.candidates){w.text(c.ranked.channel.word);w.real(c.ranked.channel.cost);w.real(c.ranked.channel.logFrequency);w.real(c.ranked.language);w.real(c.ranked.score);w.real(c.typedMargin);w.u32(std::uint32_t(c.source));}
    for(auto t:{out.timings.session,out.timings.generation,out.timings.scoring,out.timings.policy})w.real(t);return std::move(w.bytes);
}
std::vector<std::byte> encodePersonalization(const PersonalizationSnapshot& s){Writer w;w.u32(0x3150424b);w.u64(s.epoch);writeCounts(w,s.counts.unigram);writeCounts(w,s.confirmed);writeTable(w,s.counts.bigram);writeTable(w,s.counts.trigram);return std::move(w.bytes);}
PersonalizationSnapshot decodePersonalization(std::span<const std::byte> bytes){
    if(bytes.size()>4000000)throw std::invalid_argument("wire snapshot too large");Reader r{bytes};if(r.u32()!=0x3150424b)throw std::invalid_argument("unsupported personal snapshot");PersonalizationSnapshot s;s.epoch=r.u64();readCounts(r,s.counts.unigram,8000);readCounts(r,s.confirmed,1024);readTable(r,s.counts.bigram);readTable(r,s.counts.trigram);if(r.at!=bytes.size())throw std::invalid_argument("wire snapshot trailing bytes");return s;
}
}
