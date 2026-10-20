#include "../include/Personalization.hpp"
#include "../include/TextOrder.hpp"
#include <algorithm>
#include <limits>
namespace kb {
namespace {
void increment(std::int64_t& count) { if (count < std::numeric_limits<std::int64_t>::max()) ++count; }
void bump(CountRows& row, const std::string& word) {
    for (auto& [key, count] : row) if (key == word) { increment(count); return; }
    row.emplace_back(word, 1);
}
void decrement(CountRows& row, std::string_view word) {
    for (auto& [key, count] : row) if (key == word) { --count; break; }
    std::erase_if(row, [](const auto& value) { return value.second <= 0; });
}
void down(std::unordered_map<std::string, CountRows>& table, const std::string& context, std::string_view word) {
    auto it = table.find(context); if (it == table.end()) return;
    decrement(it->second, word); if (it->second.empty()) table.erase(it);
}
std::int64_t total(const CountRows& row) { std::int64_t out = 0; for (const auto& [word, count] : row) { (void)word; out += count; } return out; }
void pruneTable(std::unordered_map<std::string, CountRows>& table) {
    for (auto& [context, row] : table) {
        (void)context;
        for (auto& [word, count] : row) { (void)word; count = count >= 2 ? count >> 1 : 0; }
        std::erase_if(row, [](const auto& r) { return r.second == 0; });
        if (row.size() > 8) {
            std::sort(row.begin(), row.end(), [](const auto& a, const auto& b) { return a.second == b.second ? utf8Less(a.first, b.first) : a.second > b.second; });
            row.resize(8);
        }
    }
    std::erase_if(table, [](const auto& r) { return r.second.empty(); });
    if (table.size() > 2000) {
        std::vector<std::string> keys; for (const auto& [key, row] : table) { (void)row; keys.push_back(key); }
        std::sort(keys.begin(), keys.end(), [&](const auto& a, const auto& b) { auto x=total(table.at(a)), y=total(table.at(b)); return x == y ? utf8Less(a,b) : x > y; });
        for (std::size_t i=2000; i<keys.size(); ++i) table.erase(keys[i]);
    }
}
}
void Personalization::mutate() { ++revision_; if (counts_.use_count() != 1) counts_ = std::make_shared<PersonalCounts>(*counts_); }
void Personalization::reset(std::uint64_t epoch) { ++revision_; counts_ = std::make_shared<PersonalCounts>(); confirmed_.clear(); recent_.clear(); kept_.clear(); epoch_ = epoch; }
void Personalization::install(PersonalizationSnapshot snapshot) { reset(snapshot.epoch); counts_ = std::make_shared<PersonalCounts>(std::move(snapshot.counts)); confirmed_ = std::move(snapshot.confirmed); }
void Personalization::learn(std::span<const std::string> context, std::string word) {
    mutate(); increment(counts_->unigram[word]);
    if (!context.empty()) bump(counts_->bigram[context.back()], word);
    if (context.size()>=2) bump(counts_->trigram[context[context.size()-2]+" "+context.back()], word);
    recent_.push_back({{context.begin(),context.end()},std::move(word)}); if(recent_.size()>64) recent_.erase(recent_.begin());
}
void Personalization::demote(std::string_view word) {
    mutate(); auto found=counts_->unigram.find(std::string(word));
    if(found!=counts_->unigram.end()) { if(found->second>1) --found->second; else counts_->unigram.erase(found); }
    auto event=std::find_if(recent_.rbegin(),recent_.rend(),[&](const auto& e){return e.word==word;});
    if(event==recent_.rend())return;
    auto context=event->context; recent_.erase(std::next(event).base());
    if(!context.empty())down(counts_->bigram,context.back(),word);
    if(context.size()>=2)down(counts_->trigram,context[context.size()-2]+" "+context.back(),word);
}
void Personalization::confirm(std::string word) {
    confirmed_[word]=std::min<std::int64_t>(confirmed_[word]+1,8); kept_.insert(std::move(word));
    if(confirmed_.size()>512){for(auto& [key,count]:confirmed_){(void)key;count=count>=2?count-1:0;}std::erase_if(confirmed_,[](const auto& e){return e.second==0;});}
}
std::int64_t Personalization::confirmations(std::string_view word) const { auto it=confirmed_.find(std::string(word));return it==confirmed_.end()?0:it->second; }
std::size_t Personalization::diversity(std::string_view word,std::size_t limit) const {
    std::size_t out=0;for(const auto& [key,row]:counts_->bigram){(void)key;if(std::any_of(row.begin(),row.end(),[&](const auto& e){return e.first==word;})){++out;if(out>=limit)break;}}return out;
}
bool Personalization::prune() {
    bool changed=counts_->unigram.size()>4000||counts_->bigram.size()>2000||counts_->trigram.size()>2000;if(!changed)return false;mutate();
    if(counts_->unigram.size()>4000){
        for(auto& [key,count]:counts_->unigram){(void)key;count=count>=2?count>>1:0;}std::erase_if(counts_->unigram,[](const auto& e){return e.second==0;});
        if(counts_->unigram.size()>4000){CountRows rows(counts_->unigram.begin(),counts_->unigram.end());std::sort(rows.begin(),rows.end(),[](const auto& a,const auto& b){return a.second==b.second?utf8Less(a.first,b.first):a.second>b.second;});counts_->unigram.clear();for(std::size_t i=0;i<4000;++i)counts_->unigram.emplace(std::move(rows[i]));}
    }
    if(counts_->bigram.size()>2000)pruneTable(counts_->bigram);if(counts_->trigram.size()>2000)pruneTable(counts_->trigram);return true;
}
bool Personalization::allowsAdoption(std::string_view word,std::int64_t count,const GenerationLexicon& lexicon,std::int64_t threshold) const {
    if(count<threshold)return false;if(lexicon.contains(word)||confirmations(word)>0)return true;
    if(diversity(word)<2&&count<threshold*2)return false;
    for(const auto& row:lexicon.corrections(word,1.05,{}, {},false,{})) if(row.word!=word && row.cost<=1.05 && ((lexicon.packed&&lexicon.packed->wordID(row.word)) || (!lexicon.packed&&lexicon.base&&lexicon.base->contains(row.word))))return false;
    return true;
}
}

#include "../include/Glide.hpp"
namespace kb {
void VocabularyState::mutate() { if(generation_.use_count()!=1)generation_=std::make_shared<GenerationSnapshot>(*generation_); }
void VocabularyState::setBlocked(std::unordered_set<std::string> words){mutate();generation_->blocked=std::move(words);}
void VocabularyState::supplementary(std::string word,std::int64_t frequency,bool glide){
    if(glide&&(supplementaryGlide_.size()<768||supplementaryGlide_.contains(word)))supplementaryGlide_[word]=std::max(supplementaryGlide_[word],frequency);
}
bool VocabularyState::noteUse(const GenerationLexicon& lexicon,MutableTrie& personal,std::string word,std::int64_t count,bool allow,std::int64_t threshold,bool glide){
    bool isStatic=(lexicon.packed&&lexicon.packed->wordID(word))||(!lexicon.packed&&lexicon.base&&lexicon.base->contains(word));
    if(isStatic){mutate();auto&boost=generation_->boosts[word];boost=std::min<std::int64_t>(boost+1,100);if(generation_->boosts.size()>3000){for(auto&[key,value]:generation_->boosts){(void)key;value=value>=2?value>>1:0;}std::erase_if(generation_->boosts,[](const auto&e){return e.second==0;});}}
    else if(lexicon.supplementary&&lexicon.supplementary->contains(word)){if(auto it=supplementaryGlide_.find(word);it!=supplementaryGlide_.end())it->second=std::min<std::int64_t>(it->second+1,500);}
    else if(personal.contains(word)){personal.bump(word);auto it=personalGlide_.find(word);personalGlide_[word]=std::min<std::int64_t>((it==personalGlide_.end()?count:it->second)+1,500);}
    else if(allow&&count>=threshold){personal.insert(word,count);if(glide){personalGlide_[word]=count;if(personalGlide_.size()>384){CountRows ordered(personalGlide_.begin(),personalGlide_.end());std::sort(ordered.begin(),ordered.end(),[](const auto&a,const auto&b){return a.second==b.second?utf8Less(a.first,b.first):a.second>b.second;});personalGlide_.clear();for(std::size_t i=0;i<384;++i)personalGlide_.emplace(std::move(ordered[i]));}}return true;}
    return false;
}
std::vector<std::string> VocabularyState::dynamicWords(std::size_t limit) const {return dynamicGlideWords(CountRows(supplementaryGlide_.begin(),supplementaryGlide_.end()),CountRows(personalGlide_.begin(),personalGlide_.end()),limit);}
void VocabularyState::resetPersonalization(){mutate();generation_->boosts.clear();personalGlide_.clear();}
}
