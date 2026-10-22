#include <jni.h>
#include "Engine.hpp"
#include "EngineWire.hpp"
#include "Safety.hpp"
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <algorithm>
#include <cstring>
#include <mutex>
#include <stdexcept>
#include <limits>
namespace {
std::string bytes(JNIEnv* env,jbyteArray value){if(!value)throw std::invalid_argument("missing byte input");std::string out(std::size_t(env->GetArrayLength(value)),'\0');if(!out.empty())env->GetByteArrayRegion(value,0,jsize(out.size()),reinterpret_cast<jbyte*>(out.data()));if(env->ExceptionCheck())throw std::runtime_error("byte transport failed");return out;}
std::vector<std::string> texts(JNIEnv*env,jobjectArray array){if(!array)throw std::invalid_argument("missing text batch");std::vector<std::string> out;for(jsize i=0;i<env->GetArrayLength(array);++i){auto row=static_cast<jbyteArray>(env->GetObjectArrayElement(array,i));out.push_back(bytes(env,row));env->DeleteLocalRef(row);}return out;}
void fail(JNIEnv*env,const std::exception&e){if(env->ExceptionCheck())return;jclass type=env->FindClass("java/lang/IllegalStateException");if(type){env->ThrowNew(type,e.what());env->DeleteLocalRef(type);}}
jbyteArray output(JNIEnv*env,std::span<const std::byte> bytes){if(bytes.size()>std::size_t(INT32_MAX))throw std::length_error("output too large");auto out=env->NewByteArray(jsize(bytes.size()));if(out&&!bytes.empty())env->SetByteArrayRegion(out,0,jsize(bytes.size()),reinterpret_cast<const jbyte*>(bytes.data()));return out;}
struct Mapping {
    void* data=MAP_FAILED;std::size_t size=0;
    explicit Mapping(const std::string&path){
        if(path.find('\0')!=path.npos)throw std::invalid_argument("NUL in path");int fd=open(path.c_str(),O_RDONLY|O_CLOEXEC);if(fd<0)throw std::runtime_error("cannot open dictionary");struct stat s{};
        if(fstat(fd,&s)||!S_ISREG(s.st_mode)||s.st_size<=0||std::uintmax_t(s.st_size)>SIZE_MAX){close(fd);throw std::invalid_argument("invalid dictionary file");}
        size=std::size_t(s.st_size);data=mmap(nullptr,size,PROT_READ,MAP_PRIVATE,fd,0);close(fd);if(data==MAP_FAILED)throw std::runtime_error("cannot map dictionary");
    }
    ~Mapping(){if(data!=MAP_FAILED)munmap(data,size);}
    Mapping(const Mapping&)=delete;Mapping&operator=(const Mapping&)=delete;
};
struct NativeEngine {
    std::shared_ptr<Mapping> backing;
    std::shared_ptr<const kb::PackedLexicon> packed;
    std::shared_ptr<kb::Engine> engine;
    std::unique_ptr<kb::EngineSession> session;
    std::unique_ptr<kb::EngineState> state;
    std::unordered_map<std::string,double> penalties;
    std::mutex lane,tokenLock;
    std::shared_ptr<kb::CancellationToken> token;
    kb::DecodeOutput lastGlide;
    explicit NativeEngine(const std::string&path):backing(std::make_shared<Mapping>(path)){
        auto raw=new kb::PackedLexicon({static_cast<const std::byte*>(backing->data),backing->size});
        packed=std::shared_ptr<const kb::PackedLexicon>(raw,[owner=backing](const kb::PackedLexicon*p){delete p;(void)owner;});
        engine=std::make_shared<kb::Engine>(packed);session=engine->createSession();state=engine->createState();
    }
    std::shared_ptr<kb::CancellationToken> begin(){std::lock_guard guard(tokenLock);if(token)token->cancel();token=std::make_shared<kb::CancellationToken>();return token;}
    void cancel(){std::lock_guard guard(tokenLock);if(token)token->cancel();}

};
std::mutex registryLock;std::unordered_map<jlong,std::shared_ptr<NativeEngine>> registry;jlong nextID=1;
std::shared_ptr<NativeEngine> get(jlong handle){std::lock_guard guard(registryLock);auto found=registry.find(handle);if(found==registry.end())throw std::invalid_argument("decoder closed");return found->second;}
std::vector<double> numbers(JNIEnv*env,jdoubleArray array){if(!array)return {};std::vector<double> out(std::size_t(env->GetArrayLength(array)));if(!out.empty())env->GetDoubleArrayRegion(array,0,jsize(out.size()),out.data());if(env->ExceptionCheck())throw std::runtime_error("numeric transport failed");return out;}
void safety(NativeEngine&engine,std::string_view blob){engine.penalties=kb::parseSafetyPenalties(blob);engine.state->setSafety(engine.penalties);}
}
extern "C" JNIEXPORT jlong JNICALL Java_com_xploree_decoder_NativeKeyboardEngine_nativeOpen(JNIEnv*env,jobject,jbyteArray path,jbyteArray guard){try{auto engine=std::make_shared<NativeEngine>(bytes(env,path));safety(*engine,bytes(env,guard));std::lock_guard lock(registryLock);if(nextID==INT64_MAX)throw std::length_error("handle overflow");auto id=nextID++;registry.emplace(id,std::move(engine));return id;}catch(const std::exception&e){fail(env,e);return 0;}}
extern "C" JNIEXPORT void JNICALL Java_com_xploree_decoder_NativeKeyboardEngine_nativeClose(JNIEnv*env,jobject,jlong id){try{std::shared_ptr<NativeEngine> engine;{std::lock_guard lock(registryLock);auto it=registry.find(id);if(it==registry.end())return;engine=it->second;registry.erase(it);}engine->cancel();}catch(const std::exception&e){fail(env,e);}}
extern "C" JNIEXPORT void JNICALL Java_com_xploree_decoder_NativeKeyboardEngine_nativeCancel(JNIEnv*env,jobject,jlong id){try{std::shared_ptr<NativeEngine> engine;{std::lock_guard lock(registryLock);auto it=registry.find(id);if(it==registry.end())return;engine=it->second;}engine->cancel();}catch(const std::exception&e){fail(env,e);}}
extern "C" JNIEXPORT jbyteArray JNICALL Java_com_xploree_decoder_NativeKeyboardEngine_nativeDecode(JNIEnv*env,jobject,jlong id,jbyteArray original,jbyteArray normalized,jobjectArray context,jlongArray identity,jintArray offsets,jbyteArray flags,jdoubleArray taps,jbyteArray validity){try{
    auto engine=get(id);auto token=engine->begin();std::lock_guard lane(engine->lane);kb::DecodeInput input;
    if(!identity||env->GetArrayLength(identity)!=7)throw std::invalid_argument("identity shape");jlong fields[7];env->GetLongArrayRegion(identity,0,7,fields);input.identity={std::uint64_t(fields[0]),std::uint64_t(fields[1]),std::uint64_t(fields[2]),std::uint64_t(fields[3]),std::uint64_t(fields[4]),std::uint64_t(fields[5]),std::uint64_t(fields[6])};
    input.word=bytes(env,original);input.normalized=bytes(env,normalized);input.context=texts(env,context);input.kept=engine->state->kept(input.normalized);
    if(!offsets)throw std::invalid_argument("missing boundaries");std::vector<jint> boundaries(std::size_t(env->GetArrayLength(offsets)));env->GetIntArrayRegion(offsets,0,jsize(boundaries.size()),boundaries.data());for(auto x:boundaries){if(x<0)throw std::invalid_argument("negative boundary");input.characterOffsets.push_back(std::size_t(x));}
    auto f=bytes(env,flags);input.letterFlags.assign(f.begin(),f.end());auto xy=numbers(env,taps);if(validity){auto valid=bytes(env,validity);if(valid.size()!=input.normalized.size()||xy.size()!=valid.size()*2)throw std::invalid_argument("touch shape");for(std::size_t i=0;i<valid.size();++i)input.taps.push_back(valid[i]?std::optional(kb::TouchOffset{xy[i*2],xy[i*2+1]}):std::nullopt);}
    auto view=engine->state->view();auto result=engine->session->decode(input,view,token.get());return output(env,kb::encodeDecodeOutput(result));
}catch(const std::exception&e){fail(env,e);return nullptr;}}
extern "C" JNIEXPORT void JNICALL Java_com_xploree_decoder_NativeKeyboardEngine_nativeEvent(JNIEnv*env,jobject,jlong id,jint kind,jbyteArray word,jobjectArray context,jlong epoch){try{
    auto engine=get(id);engine->cancel();std::lock_guard lane(engine->lane);auto text=bytes(env,word);
    if(kind<0||kind>5)throw std::invalid_argument("unknown user event");
    engine->state->apply({static_cast<kb::UserEventKind>(kind),text,texts(env,context),std::uint64_t(epoch),true});
    if(kind==4)engine->session->memoryPressure();
}catch(const std::exception&e){fail(env,e);}}
extern "C" JNIEXPORT jbyteArray JNICALL Java_com_xploree_decoder_NativeKeyboardEngine_nativeExport(JNIEnv*env,jobject,jlong id){try{auto engine=get(id);std::lock_guard lane(engine->lane);return output(env,kb::encodePersonalization(engine->state->exportPersonalization()));}catch(const std::exception&e){fail(env,e);return nullptr;}}
extern "C" JNIEXPORT void JNICALL Java_com_xploree_decoder_NativeKeyboardEngine_nativeImport(JNIEnv*env,jobject,jlong id,jbyteArray blob){try{auto engine=get(id);engine->cancel();auto data=bytes(env,blob);auto snapshot=kb::decodePersonalization({reinterpret_cast<const std::byte*>(data.data()),data.size()});std::lock_guard lane(engine->lane);engine->state->importPersonalization(std::move(snapshot));engine->session->memoryPressure();}catch(const std::exception&e){fail(env,e);}}
extern "C" JNIEXPORT void JNICALL Java_com_xploree_decoder_NativeKeyboardEngine_nativeMemoryPressure(JNIEnv*env,jobject,jlong id){try{auto engine=get(id);engine->cancel();std::lock_guard lane(engine->lane);engine->session->memoryPressure();}catch(const std::exception&e){fail(env,e);}}
extern "C" JNIEXPORT void JNICALL Java_com_xploree_decoder_NativeKeyboardEngine_nativeBeginGlide(JNIEnv*env,jobject,jlong id,jobjectArray context){try{auto engine=get(id);std::lock_guard lane(engine->lane);engine->session->beginGlide(texts(env,context));engine->lastGlide={};}catch(const std::exception&e){fail(env,e);}}
extern "C" JNIEXPORT jbyteArray JNICALL Java_com_xploree_decoder_NativeKeyboardEngine_nativeGlide(JNIEnv*env,jobject,jlong id,jdoubleArray raw,jbyteArray labels,jdoubleArray centers,jdouble x,jdouble y,jlongArray identity){try{
    auto engine=get(id);auto token=engine->begin();std::lock_guard lane(engine->lane);auto path=numbers(env,raw);auto keys=bytes(env,labels);auto locations=numbers(env,centers);if(path.size()%2||locations.size()!=keys.size()*2)throw std::invalid_argument("glide shape");kb::GlideLayout layout{{},x,y};std::vector<kb::Point> points;for(std::size_t i=0;i<path.size();i+=2)points.push_back({path[i],path[i+1]});for(std::size_t i=0;i<keys.size();++i)layout.centers.emplace_back(std::uint8_t(keys[i]),kb::Point{locations[i*2],locations[i*2+1]});
    auto dynamic=engine->state->dynamicGlideWords();auto view=engine->state->view();kb::DecodeOutput result;std::vector<kb::RankedRow> rows;try{rows=engine->session->updateGlide(points,layout,view,dynamic,token.get());}catch(const kb::GlideInvalidated&){result.status=kb::EngineStatus::glideInvalidated;}if(!identity||env->GetArrayLength(identity)!=7)throw std::invalid_argument("glide identity shape");jlong f[7];env->GetLongArrayRegion(identity,0,7,f);result.identity={std::uint64_t(f[0]),std::uint64_t(f[1]),std::uint64_t(f[2]),std::uint64_t(f[3]),std::uint64_t(f[4]),std::uint64_t(f[5]),std::uint64_t(f[6])};if(result.status==kb::EngineStatus::ok&&token->cancelled())result.status=kb::EngineStatus::cancelled;else if(result.status==kb::EngineStatus::ok)for(std::size_t i=0;i<rows.size();++i){if(i<4)result.suggestions.push_back(rows[i].channel.word);if(i<24)result.candidates.push_back({rows[i],kb::CandidateSource::fuzzyLexicon,0});}if(result.status==kb::EngineStatus::ok)engine->lastGlide=result;return output(env,kb::encodeDecodeOutput(result));
}catch(const std::exception&e){fail(env,e);return nullptr;}}
extern "C" JNIEXPORT jbyteArray JNICALL Java_com_xploree_decoder_NativeKeyboardEngine_nativeEndGlide(JNIEnv*env,jobject,jlong id){try{auto engine=get(id);std::lock_guard lane(engine->lane);engine->session->endGlide();return output(env,kb::encodeDecodeOutput(engine->lastGlide));}catch(const std::exception&e){fail(env,e);return nullptr;}}
extern "C" JNIEXPORT jbyteArray JNICALL Java_com_xploree_decoder_NativeKeyboardEngine_nativeMetadata(JNIEnv*env,jobject,jlong id){try{auto engine=get(id);std::vector<std::byte> out;auto add=[&](std::uint32_t value){for(int i=0;i<4;++i)out.push_back(std::byte(value>>(i*8)));};auto ids=engine->packed->textMetadataIDs();add(std::uint32_t(ids.size()));for(auto word:ids){auto text=engine->packed->word(word);add(std::uint32_t(word));add(std::uint32_t(text.size()));for(unsigned char c:text)out.push_back(std::byte(c));}return output(env,out);}catch(const std::exception&e){fail(env,e);return nullptr;}}
extern "C" JNIEXPORT void JNICALL Java_com_xploree_decoder_NativeKeyboardEngine_nativeInstallMetadata(JNIEnv*env,jobject,jlong id,jlongArray values){try{auto engine=get(id);std::lock_guard lane(engine->lane);if(!values||env->GetArrayLength(values)%4)throw std::invalid_argument("metadata shape");std::vector<jlong> row(std::size_t(env->GetArrayLength(values)));env->GetLongArrayRegion(values,0,jsize(row.size()),row.data());std::vector<kb::PackedLexicon::TextMetadata> metadata;for(std::size_t i=0;i<row.size();i+=4)metadata.push_back({std::int32_t(row[i]),std::size_t(row[i+1]),row[i+2]<0?std::nullopt:std::optional(std::uint8_t(row[i+2])),row[i+3]<0?std::nullopt:std::optional(std::uint8_t(row[i+3]))});engine->packed->installTextMetadata(metadata);engine->packed->warmAnchors();}catch(const std::exception&e){fail(env,e);}}
