#include "../include/NeuralSearch.hpp"
#include <algorithm>
#include <bit>
#include <cmath>
#include <cstdio>
#include <limits>
namespace kb {
Tokenizer::Tokenizer(std::span<const uint8_t> data) {
    auto u32 = [&](size_t p) { return uint32_t(data[p]) | uint32_t(data[p+1])<<8 | uint32_t(data[p+2])<<16 | uint32_t(data[p+3])<<24; };
    if(data.size()<16 || u32(0)!=0x4B42544B || u32(4)!=1) return;
    const size_t count=u32(8), offsets=16+4*count, blob=offsets+4*(count+1);
    if(!count || blob>data.size() || u32(12)>=count || count>INT32_MAX) return;
    unknown=static_cast<int32_t>(u32(12));
    for(size_t i=0;i<count;++i) {
        const size_t a=u32(offsets+4*i), b=u32(offsets+4*(i+1));
        if(a>b || b>data.size()-blob) return;
        std::string piece(reinterpret_cast<const char*>(data.data()+blob+a),b-a);
        pieces.push_back(piece); lookup[piece]={static_cast<int32_t>(i),std::bit_cast<float>(u32(16+4*i))};
        if(piece=="<pad>") pad=static_cast<int32_t>(i);
        if(piece=="<en>") english=static_cast<int32_t>(i);
        const bool start=piece.starts_with("▁"); const auto body=piece.substr(start?3:0);
        const bool alpha=!body.empty() && std::all_of(body.begin(),body.end(),[](unsigned char c){return(c>='a'&&c<='z')||(c>='A'&&c<='Z')||c=='\'';});
        starts.push_back(start&&alpha); continuations.push_back(!start&&alpha);
    }
    valid=true;
}
void Tokenizer::setLengths(std::span<const uint32_t> lengths) {
    maximum=1; for(auto n:lengths) maximum=std::max(maximum,size_t(n)); maximum=std::min(maximum,size_t(24));
}
std::vector<int32_t> Tokenizer::encode(std::span<const std::string> chars) const {
    const auto n=chars.size(); if(!n) return {};
    std::vector<float> scores(n+1,-std::numeric_limits<float>::infinity()); scores[0]=0;
    std::vector<size_t> back(n+1); std::vector<std::vector<int32_t>> ids(n+1,{unknown});
    for(size_t end=1;end<=n;++end) {
        for(size_t start=end>maximum?end-maximum:0;start<end;++start) if(std::isfinite(scores[start])) {
            std::string piece; for(size_t k=start;k<end;++k) piece+=chars[k];
            const auto found=lookup.find(piece);
            if(found!=lookup.end() && scores[start]+found->second.score>scores[end]) {
                scores[end]=scores[start]+found->second.score;back[end]=start;ids[end]={found->second.id};
            }
        }
        if(!std::isfinite(scores[end])) {
            std::vector<int32_t> bytes;
            for(unsigned char byte:chars[end-1]) { char key[7]; std::snprintf(key,sizeof(key),"<0x%02X>",byte); const auto it=lookup.find(key); if(it!=lookup.end()) bytes.push_back(it->second.id); }
            ids[end]=bytes.size()==chars[end-1].size()?bytes:std::vector<int32_t>{unknown};
            scores[end]=scores[end-1]-20;back[end]=end-1;
        }
    }
    std::vector<int32_t> out; for(size_t k=n;k>0;k=back[k]) out.insert(out.end(),ids[k].rbegin(),ids[k].rend());
    std::reverse(out.begin(),out.end());return out;
}
std::string Tokenizer::word(std::span<const int32_t> ids) const {
    std::string out;for(auto id:ids) if(id>=0&&size_t(id)<pieces.size()) out+=pieces[size_t(id)];
    size_t p=0;while((p=out.find("▁",p))!=std::string::npos) out.erase(p,3);
    for(auto& c:out) if(c>='A'&&c<='Z') c=char(c+32);
    return out;
}
bool logProbabilities(std::vector<float>& values) {
    if(values.empty()||!std::all_of(values.begin(),values.end(),[](float v){return std::isfinite(v);})) return false;
    float maximum=-std::numeric_limits<float>::max();for(auto v:values) if(v>maximum) maximum=v;
    float sum=0;for(auto v:values) sum+=std::exp(v-maximum);const float norm=maximum+std::log(sum);
    for(auto& v:values) v-=norm;
    return true;
}
double boundaryProbability(std::span<const float> values,std::span<const uint8_t> continuation) {
    const size_t n=std::min(values.size(),continuation.size());float maximum=-std::numeric_limits<float>::max();
    for(size_t i=0;i<n;++i) if(!continuation[i]&&values[i]>maximum) maximum=values[i];
    if(maximum<=-std::numeric_limits<float>::max()) return -30;
    float sum=0;for(size_t i=0;i<n;++i) if(!continuation[i]) sum+=std::exp(values[i]-maximum);
    return double(maximum+std::log(sum));
}
std::vector<int32_t> topIndices(std::span<const float> values,size_t count,std::span<const uint8_t> allowed) {
    count=std::min(count,values.size());if(!count)return {};
    struct Row { float value;int32_t index; };std::vector<Row> top;top.reserve(count);float threshold=-std::numeric_limits<float>::max();
    for(size_t i=0;i<values.size();++i) if(i<allowed.size()&&allowed[i]) {
        if(top.size()<count) {top.push_back({values[i],static_cast<int32_t>(i)});if(top.size()==count) {std::stable_sort(top.begin(),top.end(),[](auto a,auto b){return a.value>b.value;});threshold=top.back().value;}}
        else if(values[i]>threshold) {top.back()={values[i],static_cast<int32_t>(i)};size_t p=count-1;while(p&&top[p].value>top[p-1].value){std::swap(top[p],top[p-1]);--p;}threshold=top.back().value;}
    }
    std::sort(top.begin(),top.end(),[](auto a,auto b){return a.value==b.value?a.index<b.index:a.value>b.value;});std::vector<int32_t> out;for(auto r:top)out.push_back(r.index);return out;
}
}
namespace kb {
std::vector<NeuralWord> generateWords(const Tokenizer& tokenizer,int32_t previous,size_t state,
    std::span<const uint8_t> allowedStarts,size_t width,size_t branch,size_t depth,
    const NeuralInference& infer,const std::function<bool(const std::string&)>& known,const std::function<bool()>& cancelled) {
    struct Hypothesis {std::vector<int32_t> pieces;double probability;size_t state;int32_t previous;};
    std::vector<Hypothesis> frontier{{{},0,state,previous}};
    std::vector<NeuralWord> completed;std::unordered_map<std::string,size_t> indices;
    std::vector<uint8_t> initialLegal(tokenizer.starts.size());
    for(size_t i=0;i<initialLegal.size()&&i<allowedStarts.size();++i)
        initialLegal[i]=tokenizer.starts[i]&&allowedStarts[i];
    for(size_t d=0;d<=depth;++d) {
        if(cancelled())return {};std::vector<Hypothesis> extended;
        for(const auto& hypothesis:frontier) {
            if(cancelled())return {};auto step=infer(hypothesis.previous,hypothesis.state);
            if(!step||!logProbabilities(step->logits)) continue;
            if(!hypothesis.pieces.empty()) {
                auto word=tokenizer.word(hypothesis.pieces);
                if(!word.empty()&&known(word)) {
                    const auto score=hypothesis.probability+boundaryProbability(step->logits,tokenizer.continuations);
                    auto [it,inserted]=indices.emplace(word,completed.size());
                    if(inserted)completed.emplace_back(word,score);else completed[it->second].second=std::max(completed[it->second].second,score);
                }
            }
            if(d==depth)continue;
            const auto& legal=hypothesis.pieces.empty()?initialLegal:tokenizer.continuations;
            for(auto token:topIndices(step->logits,branch,legal)) {
                auto ids=hypothesis.pieces;ids.push_back(token);
                extended.push_back({std::move(ids),hypothesis.probability+double(step->logits[size_t(token)]),step->state,token});
            }
        }
        if(extended.empty())break;
        std::stable_sort(extended.begin(),extended.end(),[](const auto& a,const auto& b){return a.probability>b.probability;});
        if(extended.size()>width)extended.resize(width);frontier=std::move(extended);
    }
    return completed;
}
std::optional<std::vector<NeuralWord>> scoreWords(const Tokenizer& tokenizer,std::span<const std::string> words,
    std::span<const std::vector<int32_t>> tokens,int32_t previous,size_t state,const NeuralInference& infer,const std::function<bool()>& cancelled) {
    if(cancelled())return std::nullopt;
    auto first=infer(previous,state);if(!first||!logProbabilities(first->logits))return std::nullopt;
    std::vector<NeuralWord> out;
    for(size_t w=0;w<words.size()&&w<tokens.size();++w) {
        if(cancelled())return std::nullopt;const auto& ids=tokens[w];
        if(ids.empty()||ids.front()<0||size_t(ids.front())>=first->logits.size())continue;
        double probability=first->logits[size_t(ids.front())];auto current=first->state;auto prior=ids.front();
        for(size_t t=1;t<ids.size();++t) {
            if(cancelled())return std::nullopt;auto step=infer(prior,current);
            if(!step||!logProbabilities(step->logits)||ids[t]<0||size_t(ids[t])>=step->logits.size())return std::nullopt;
            probability+=double(step->logits[size_t(ids[t])]);current=step->state;prior=ids[t];
        }
        auto ending=infer(prior,current);if(!ending||!logProbabilities(ending->logits))return std::nullopt;
        probability+=boundaryProbability(ending->logits,tokenizer.continuations);
        if(!std::isfinite(probability))return std::nullopt;out.emplace_back(words[w],probability);
    }
    return out;
}
ContextPlan contextPlan(std::span<const int32_t> tokens,std::span<const int32_t> cached,int32_t pad) {
    const bool reuse=!cached.empty()&&cached.size()<=tokens.size()&&std::equal(cached.begin(),cached.end(),tokens.begin());
    return {reuse,reuse?cached.size():0,reuse?cached.back():pad};
}
}
namespace kb {
std::vector<int32_t> trimmedContext(std::span<const int32_t> tokens,std::optional<int32_t> languageMode,size_t sequenceLength,size_t maximumCandidateTokens) {
    const size_t capacity=std::max<size_t>(1,sequenceLength>maximumCandidateTokens?sequenceLength-maximumCandidateTokens:1);
    if(tokens.size()<=capacity)return {tokens.begin(),tokens.end()};
    if(languageMode&&capacity>1) {std::vector<int32_t> out{*languageMode};for(auto id:tokens)if(id!=*languageMode)out.push_back(id);if(out.size()>capacity)out.erase(out.begin()+1,out.end()-static_cast<ptrdiff_t>(capacity-1));return out;}
    return {tokens.end()-static_cast<ptrdiff_t>(capacity),tokens.end()};
}
}
namespace kb {
std::optional<size_t> threadContext(std::span<const int32_t> tokens,int32_t previous,size_t state,const NeuralInference& infer,const std::function<bool()>& cancelled) {
    for(auto token:tokens){if(cancelled())return std::nullopt;auto step=infer(previous,state);if(!step)return std::nullopt;state=step->state;previous=token;}return state;
}
}
namespace kb {
std::vector<std::string> filterKnownWords(std::span<const std::string> words,const GenerationLexicon& lexicon,std::span<const std::string> firstLetters) {
    std::array<uint8_t,256> allowed{};for(const auto& l:firstLetters)if(!l.empty())allowed[static_cast<uint8_t>(l.front())]=1;
    std::vector<std::string> out;for(const auto& word:words)if(lexicon.contains(word)&&!lexicon.isBlocked(word)&&(firstLetters.empty()||(!word.empty()&&allowed[static_cast<uint8_t>(word.front())])))out.push_back(word);return out;
}
std::vector<std::string> lastContextWords(std::span<const std::string> words,size_t limit) {
    const size_t start=words.size()>limit?words.size()-limit:0;return {words.begin()+static_cast<ptrdiff_t>(start),words.end()};
}
}
