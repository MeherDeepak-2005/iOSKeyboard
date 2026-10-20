#include "../DecoderCore/include/NeuralSearch.hpp"
#include <cassert>
#include <cmath>
#include <cstring>
#include <iostream>
#include <vector>
using namespace kb;
static void put32(std::vector<uint8_t>& d,uint32_t v){for(int i=0;i<4;++i)d.push_back(uint8_t(v>>(8*i)));}
static std::vector<uint8_t> fixture(){
    const std::vector<std::string> pieces={"<pad>","<unk>","<en>","▁a","▁ab","b","▁b","x"};
    std::vector<uint8_t> d;put32(d,0x4B42544B);put32(d,1);put32(d,uint32_t(pieces.size()));put32(d,1);
    for(size_t i=0;i<pieces.size();++i)put32(d,std::bit_cast<uint32_t>(i==4?10.f:0.f));
    size_t off=0;put32(d,0);for(const auto& p:pieces){off+=p.size();put32(d,uint32_t(off));}
    for(const auto& p:pieces)d.insert(d.end(),p.begin(),p.end());return d;
}
int main(){
    auto data=fixture();Tokenizer tokenizer(data);assert(tokenizer.valid&&tokenizer.pad==0&&tokenizer.english==2);
    std::array<uint32_t,1> lengths{3};tokenizer.setLengths(lengths);
    std::vector<std::string> chars{"▁","a","b"};auto ids=tokenizer.encode(chars);assert(ids.size()==1&&ids[0]==4&&tokenizer.word(ids)=="ab");
    std::vector<float> logits{0,1,2};assert(logProbabilities(logits));float sum=0;for(auto x:logits)sum+=std::exp(x);assert(std::abs(sum-1)<1e-5);
    std::vector<uint8_t> continuation{1,0,1};assert(std::abs(boundaryProbability(logits,continuation)-logits[1])<1e-5);
    std::vector<float> ranked{.5f,.9f,.9f,.1f};std::vector<uint8_t> allowed{1,1,1,0};auto top=topIndices(ranked,2,allowed);assert((top==std::vector<int32_t>{1,2}));
    std::vector<int32_t> context{2,3,4},cached{2,3};auto plan=contextPlan(context,cached,0);assert(plan.reuse&&plan.start==2&&plan.previous==3);
    std::vector<std::string> words{"a"};std::vector<std::vector<int32_t>> tokenRows{{3}};
    auto inference=[](int32_t token,size_t state)->std::optional<NeuralStep>{return NeuralStep{{float(token),1,0,2,3,4,5,6},state+1};};
    auto score=scoreWords(tokenizer,words,tokenRows,2,0,inference,[]{return false;});assert(score&&score->size()==1&&std::isfinite(score->front().second));
    auto cancelled=scoreWords(tokenizer,words,tokenRows,2,0,inference,[]{return true;});assert(!cancelled);
    std::vector<uint8_t> starts(tokenizer.pieces.size());starts[3]=1;
    auto beam=[](int32_t,size_t state)->std::optional<NeuralStep>{return NeuralStep{{0,0,0,5,10,1,2,0},state+1};};
    auto generated=generateWords(tokenizer,2,0,starts,2,2,1,beam,
        [](const std::string& word){return word=="a";},[]{return false;});
    assert(generated.size()==1&&generated[0].first=="a"&&std::isfinite(generated[0].second));
    std::cout<<"Neural tokenization and scoring goldens passed\n";
}
