#include "../include/Glide.hpp"
#include <algorithm>
#include <cmath>
#include <limits>
#include <numeric>
namespace kb {
namespace {
double distance(Point a, Point b) { return std::hypot(a.x - b.x, a.y - b.y); }
std::optional<Point> center(std::uint8_t c) { if (auto p = grid(c)) return Point{p->x, p->y}; return {}; }
constexpr double maximum = std::numeric_limits<double>::max();
}
Point toGrid(Point p, const GlideLayout& layout) {
    if (layout.centers.empty()) return p;
    auto reference = layout.centers.front();
    for (const auto& key : layout.centers) if (key.first == 'q') { reference = key; break; }
    auto anchor = center(reference.first).value_or(Point{});
    return {anchor.x + (p.x - reference.second.x) / layout.xPitch, anchor.y + (p.y - reference.second.y) / layout.yPitch};
}
std::vector<Point> resample(std::span<const Point> points, double spacing) {
    if (points.size() < 2 || !(spacing > 0)) return {points.begin(), points.end()};
    std::vector<Point> out{points.front()}; Point previous = points.front(); std::size_t i = 1; double accumulated = 0;
    while (i < points.size()) {
        auto d = distance(points[i], previous);
        if (d > 0 && accumulated + d >= spacing) {
            auto ratio = (spacing - accumulated) / d;
            Point p{previous.x + (points[i].x - previous.x) * ratio, previous.y + (points[i].y - previous.y) * ratio};
            out.push_back(p); previous = p; accumulated = 0;
        } else { accumulated += d; previous = points[i]; ++i; }
    }
    if (distance(out.back(), points.back()) > 1e-6) out.push_back(points.back());
    return out;
}
std::vector<std::size_t> pivots(std::span<const Point> points, double threshold) {
    std::vector<std::size_t> out;
    if (points.size() < 3) { out.resize(points.size()); std::iota(out.begin(), out.end(), 0); return out; }
    out.push_back(0);
    for (std::size_t i = 1; i + 1 < points.size(); ++i) {
        Point a{points[i].x - points[i - 1].x, points[i].y - points[i - 1].y};
        Point b{points[i + 1].x - points[i].x, points[i + 1].y - points[i].y};
        auto m1 = std::hypot(a.x, a.y), m2 = std::hypot(b.x, b.y);
        if (m1 > 0 && m2 > 0 && (a.x * b.x + a.y * b.y) / (m1 * m2) < threshold) out.push_back(i);
    }
    out.push_back(points.size() - 1); return out;
}
std::vector<std::uint8_t> lettersNear(Point point, double radius, std::size_t maxCount) {
    std::vector<std::pair<std::uint8_t, double>> values;
    for (auto row : {"qwertyuiop", "asdfghjkl", "zxcvbnm"}) for (unsigned char c : std::string_view(row))
        values.emplace_back(c, distance(*center(c), point));
    std::stable_sort(values.begin(), values.end(), [](const auto& a, const auto& b) { return a.second < b.second; });
    std::vector<std::uint8_t> out;
    for (const auto& [letter, d] : values) { if (d > radius || out.size() >= maxCount) break; out.push_back(letter); }
    if (out.empty()) out.push_back(values.front().first);
    return out;
}
std::optional<std::uint8_t> nearestLetter(Point point) {
    double best = maximum; std::optional<std::uint8_t> out;
    for (auto row : {"qwertyuiop", "asdfghjkl", "zxcvbnm"}) for (unsigned char c : std::string_view(row)) {
        auto p = *center(c); auto d = (p.x - point.x) * (p.x - point.x) + (p.y - point.y) * (p.y - point.y);
        if (d < best) { best = d; out = c; }
    }
    return out;
}
std::optional<ProcessedGlide> preprocess(std::span<const Point> raw, const GlideLayout& layout,
        double spacing, std::span<const double> times) {
    if (raw.size() < 2 || layout.centers.empty() || !(layout.xPitch > 0) || !(layout.yPitch > 0)) return {};
    std::vector<Point> points; for (auto p : raw) points.push_back(toGrid(p, layout));
    auto samples = resample(points, spacing); if (samples.size() < 2) return {};
    auto turns = pivots(samples); std::vector<std::uint8_t> dwell;
    if (raw.size() >= 3 && times.size() == raw.size()) {
        std::vector<double> speed(raw.size(), maximum);
        for (std::size_t i = 1; i < raw.size(); ++i) {
            auto dt = times[i] - times[i - 1]; if (dt > 1e-4) speed[i] = distance(points[i], points[i - 1]) / dt;
        }
        std::vector<double> finite; for (auto value : speed) if (std::isfinite(value)) finite.push_back(value);
        std::sort(finite.begin(), finite.end());
        if (!finite.empty()) {
            auto median = finite[finite.size() / 2], slow = 0.45 * median;
            std::size_t i = 1;
            while (i + 1 < raw.size()) {
                if (!(std::isfinite(speed[i]) && speed[i] < slow && speed[i] <= speed[i - 1] && speed[i] <= speed[i + 1])) { ++i; continue; }
                std::size_t index = 0; double best = maximum;
                for (std::size_t k = 0; k < samples.size(); ++k) {
                    auto x = samples[k].x - points[i].x, y = samples[k].y - points[i].y;
                    auto d = x * x + y * y; if (d < best) { best = d; index = k; }
                }
                turns.push_back(index); auto j = i;
                while (j + 1 < raw.size() && std::isfinite(speed[j + 1]) && speed[j + 1] < median) ++j;
                if (times[j] - times[i] >= 0.09) if (auto letter = nearestLetter(points[i]))
                    if (distance(points[i], *center(*letter)) < 0.5) dwell.push_back(*letter);
                i = std::max(j, i + 1);
            }
        }
        std::sort(turns.begin(), turns.end()); turns.erase(std::unique(turns.begin(), turns.end()), turns.end());
    }
    return ProcessedGlide{std::move(samples), std::move(turns), std::move(dwell)};
}
std::vector<Point> resampleN(std::span<const Point> points, std::size_t count) {
    if (points.size() < 2 || count < 2) return {points.begin(), points.end()};
    double length = 0; for (std::size_t i = 1; i < points.size(); ++i) length += distance(points[i - 1], points[i]);
    if (!(length > 0)) return std::vector<Point>(count, points.front());
    auto step = length / double(count - 1); std::vector<Point> out{points.front()};
    std::size_t i = 1; double accumulated = 0; auto previous = points.front();
    while (out.size() < count - 1 && i < points.size()) {
        auto d = distance(previous, points[i]);
        if (accumulated + d >= step && d > 0) {
            auto ratio = (step - accumulated) / d;
            Point p{previous.x + (points[i].x - previous.x) * ratio, previous.y + (points[i].y - previous.y) * ratio};
            out.push_back(p); previous = p; accumulated = 0;
        } else { accumulated += d; previous = points[i]; ++i; }
    }
    while (out.size() < count) out.push_back(points.back()); return out;
}
namespace {
std::vector<Point> tangents(std::span<const Point> points) {
    std::vector<Point> out(points.size());
    if (points.size() < 2) return out;
    for (std::size_t i = 0; i < points.size(); ++i) {
        auto a = points[i ? i - 1 : 0], b = points[std::min(i + 1, points.size() - 1)];
        auto x = b.x - a.x, y = b.y - a.y, m = std::hypot(x, y);
        if (m > 1e-9) out[i] = {x / m, y / m};
    }
    return out;
}
double shape(std::span<const Point> observed, std::span<const Point> observedTangents, std::span<const Point> letters, int band, double direction) {
    auto ideal = letters.size() == 1 ? std::vector<Point>(32, letters.front()) : resampleN(letters, 32);
    if (ideal.size() != 32) return maximum;
    auto idealTangents = direction > 0 ? tangents(ideal) : std::vector<Point>{};
    std::vector<double> previous(33, maximum), current(33, maximum); previous[0] = 0;
    for (int i = 1; i <= 32; ++i) {
        std::fill(current.begin(), current.end(), maximum);
        for (int j = std::max(1, i - band); j <= std::min(32, i + band); ++j) {
            auto d = distance(observed[i - 1], ideal[j - 1]);
            if (direction > 0) { auto a = observedTangents[i - 1], b = idealTangents[j - 1]; d += direction * (1 - (a.x * b.x + a.y * b.y)); }
            current[j] = d + std::min(previous[j], std::min(current[j - 1], previous[j - 1]));
        } previous.swap(current);
    } return previous[32] / 32.0;
}
std::optional<std::vector<Point>> wordPath(std::string_view word) {
    std::vector<Point> points;
    for (std::uint8_t c : word) { if (c == apostrophe) continue; auto p = center(c); if (!p) return {}; points.push_back(*p); }
    if (points.empty()) return {}; return points;
}
}
std::optional<std::vector<Point>> idealPath(std::string_view word, std::size_t count) {
    if (count < 2) return {};
    auto path = wordPath(word); if (!path) return {};
    return path->size() == 1 ? std::vector<Point>(count, path->front()) : resampleN(*path, count);
}
std::optional<double> shapeCost(std::string_view word, std::span<const Point> points, int band, double direction) {
    if (points.size() < 2) return {};
    auto observed = resampleN(points, 32); if (observed.size() != 32) return {};
    auto letters = wordPath(word); if (!letters) return {};
    auto t = direction > 0 ? tangents(observed) : std::vector<Point>{};
    return shape(observed, t, *letters, band, direction);
}
std::vector<ChannelCandidate> decodeGlide(std::span<const Point> points, const PackedLexicon& lexicon,
        std::size_t width, int band, double frequency, double direction, double seedRadius, std::size_t window,
        const std::function<bool()>& cancel) {
    if (!lexicon.hasTrie() || points.size() < 2 || !width || (cancel && cancel())) return {};
    auto observed = resampleN(points, 32); if (observed.size() != 32) return {};
    auto obsTan = direction > 0 ? tangents(observed) : std::vector<Point>{};
    struct Path { Point point; std::int64_t parent; };
    std::vector<Path> arena; arena.reserve(std::max<std::size_t>(256, width * 20));
    auto addPath = [&](Point p, std::int64_t parent) { arena.push_back({p, parent}); return std::int64_t(arena.size() - 1); };
    std::vector<ChannelCandidate> result; std::unordered_map<std::string, std::size_t> indices;
    auto emit = [&](std::size_t node, std::int64_t index) {
        auto record = lexicon.trieRecord(node); if (!record.wordID) return;
        std::string word(lexicon.word(*record.wordID)); if (word.size() < 2) return;
        std::vector<Point> path;
        while (index >= 0) { path.push_back(arena[index].point); index = arena[index].parent; }
        std::reverse(path.begin(), path.end());
        auto cost = shape(observed, obsTan, path, band, direction);
        auto [found, inserted] = indices.emplace(word, result.size());
        if (inserted) result.push_back({word, cost, 0}); else if (cost < result[found->second].cost) result[found->second].cost = cost;
    };
    struct Hyp { std::size_t node, j; double prune, key; std::int64_t path; };
    auto better = [](const Hyp& a, const Hyp& b) { return a.key == b.key ? a.node < b.node : a.key < b.key; };
    auto best = [&](const std::vector<Hyp>& all) {
        if (all.size() <= width) return all;
        std::vector<Hyp> heap;
        for (const auto& h : all) {
            if (heap.size() < width) {
                heap.push_back(h); auto c = heap.size() - 1;
                while (c) { auto p = (c - 1) / 2; if (!better(heap[p], heap[c])) break; std::swap(heap[p], heap[c]); c = p; }
            } else if (better(h, heap[0])) {
                heap[0] = h; std::size_t p = 0;
                while (true) { auto l = p * 2 + 1; if (l >= heap.size()) break; auto r = l + 1, worst = l;
                    if (r < heap.size() && better(heap[l], heap[r])) worst = r;
                    if (!better(heap[p], heap[worst])) break; std::swap(heap[p], heap[worst]); p = worst; }
            }
        } return heap;
    };
    auto key = [&](double prune, std::size_t node) { return prune - frequency * std::log(double(lexicon.trieRecord(node).maxFrequency) + 1); };
    struct Seed { std::size_t node; Point p; double d; };
    std::vector<Seed> seeds;
    auto root = lexicon.trieRecord(0);
    for (std::size_t node = root.firstChild; node < root.firstChild + root.childCount; ++node)
        if (auto p = center(lexicon.trieRecord(node).label)) seeds.push_back({node, *p, distance(*p, observed[0])});
    std::stable_sort(seeds.begin(), seeds.end(), [](const auto& a, const auto& b) { return a.d < b.d; });
    std::vector<Hyp> beam;
    for (std::size_t i = 0; i < seeds.size(); ++i) { const auto& s = seeds[i]; if (s.d <= seedRadius || i < 4) {
        auto path = addPath(s.p, -1); beam.push_back({s.node, 0, s.d, key(s.d, s.node), path}); emit(s.node, path);
    }}
    beam = best(beam);
    for (int depth = 1; depth < 22; ++depth) {
        if (cancel && cancel()) return {};
        std::vector<Hyp> next; next.reserve(width * 12);
        for (const auto& h : beam) {
            auto parent = lexicon.trieRecord(h.node);
            for (std::size_t node = parent.firstChild; node < parent.firstChild + parent.childCount; ++node) {
                auto label = lexicon.trieRecord(node).label;
                if (label == apostrophe) { next.push_back({node, h.j, h.prune, key(h.prune, node), h.path}); emit(node, h.path); continue; }
                auto p = center(label); if (!p) continue;
                auto j = h.j; auto d = distance(observed[j], *p);
                for (auto k = h.j + 1; k < std::min<std::size_t>(32, h.j + 1 + window); ++k)
                    if (auto value = distance(observed[k], *p); value < d) { d = value; j = k; }
                auto prune = h.prune + d; auto path = addPath(*p, h.path);
                next.push_back({node, j, prune, key(prune, node), path}); emit(node, path);
            }
        }
        if (next.empty()) break; beam = best(next);
    }
    return result;
}
std::vector<Point> GlideResampler::append(std::span<const Point> points) {
    std::vector<Point> out;
    if (!(spacing_ > 0)) return out;
    for (auto target : points) {
        if (!last_) { last_ = target; samples.push_back(target); out.push_back(target); continue; }
        auto cursor = *last_; auto remaining = distance(target, cursor);
        while (remaining > 0 && distance_ + remaining >= spacing_) {
            auto ratio = (spacing_ - distance_) / remaining;
            cursor = {cursor.x + (target.x - cursor.x) * ratio, cursor.y + (target.y - cursor.y) * ratio};
            samples.push_back(cursor); out.push_back(cursor); distance_ = 0; remaining = distance(target, cursor);
        } distance_ += remaining; last_ = target;
    }
    return out;
}
OnlineGlide::OnlineGlide(std::vector<Point> path) : ideal(std::move(path)) { previous_.assign(ideal.size() + 1, std::numeric_limits<double>::infinity()); previous_[0] = 0; }
void OnlineGlide::consume(std::span<const Point> points) {
    for (auto point : points) {
        std::vector<double> current(ideal.size() + 1, std::numeric_limits<double>::infinity());
        for (std::size_t j = 1; j <= ideal.size(); ++j) current[j] = distance(point, ideal[j - 1]) + std::min(previous_[j], std::min(current[j - 1], previous_[j - 1]));
        previous_.swap(current); ++sampleCount;
    }
}
double OnlineGlide::prefixCost() const {
    if (!sampleCount) return std::numeric_limits<double>::infinity();
    double best = std::numeric_limits<double>::infinity();
    for (std::size_t j = 1; j <= ideal.size(); ++j) if (std::isfinite(previous_[j]))
        best = std::min(best, previous_[j] / double(std::max<std::size_t>(1, sampleCount + j)) + double(ideal.size() - j) * 0.018);
    return best;
}

bool StreamingGlide::consume(std::span<const Point> raw, const GlideLayout& layout) {
    if (invalid || raw.size() < rawCount_ || !(layout.xPitch > 0) || !(layout.yPitch > 0)) { invalid = true; return false; }
    if (pitch_ && (std::abs(pitch_->first - layout.xPitch) > 0.01 || std::abs(pitch_->second - layout.yPitch) > 0.01)) { invalid = true; return false; }
    pitch_ = {layout.xPitch, layout.yPitch};
    std::vector<Point> suffix; for (auto point : raw.subspan(rawCount_)) suffix.push_back(toGrid(point, layout));
    rawCount_ = raw.size(); auto added = resampler_.append(suffix);
    for (auto& [word, candidate] : candidates_) { (void)word; candidate.consume(added); }
    needsAugmentation = false;
    if (!resampler_.samples.empty()) {
        first_ = lettersNear(resampler_.samples.front(), 1.3, 3); last_ = lettersNear(resampler_.samples.back(), 1.3, 3);
        needsAugmentation = candidates_.empty() || first_ != previousFirst_ || last_ != previousLast_;
    }
    return true;
}
void StreamingGlide::augment(const GenerationLexicon& lexicon, std::span<const std::string> contextWords, std::span<const std::string> dynamicWords) {
    if (!needsAugmentation) return;
    previousFirst_ = first_; previousLast_ = last_;
    std::vector<std::string> proposed;
    if (candidates_.empty()) {
        proposed.assign(contextWords.begin(), contextWords.end());
        if (lexicon.packed) for (auto first : first_) {
            char byte = char(first); for (const auto& word : lexicon.packed->completions(std::string_view(&byte, 1), 72)) proposed.push_back(word.word);
        }
    }
    if (lexicon.packed) { auto anchored = lexicon.packed->anchorWords(first_, last_, 40); proposed.insert(proposed.end(), anchored.begin(), anchored.end()); }
    for (const auto& word : dynamicWords) if (!word.empty() && std::find(first_.begin(), first_.end(), std::uint8_t(word.front())) != first_.end() &&
        std::find(last_.begin(), last_.end(), std::uint8_t(word.back())) != last_.end()) proposed.push_back(word);
    for (auto word : proposed) {
        if (candidates_.size() >= 384) break;
        for (auto& c : word) if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
        if (lexicon.characterCount(word) < 2 || words_.contains(word) || lexicon.isBlocked(word)) continue;
        auto path = idealPath(word, 24); if (!path) continue;
        OnlineGlide candidate(std::move(*path)); candidate.consume(resampler_.samples);
        candidates_.emplace_back(word, std::move(candidate)); words_.insert(word);
    }
    needsAugmentation = false;
}
std::vector<ChannelCandidate> StreamingGlide::rows() const {
    if (resampler_.samples.size() < 2) return {};
    std::vector<ChannelCandidate> out;
    for (const auto& [word, candidate] : candidates_) if (std::isfinite(candidate.prefixCost())) out.push_back({word, candidate.prefixCost(), 0});
    return out;
}
std::vector<ChannelCandidate> augmentGlide(const GenerationLexicon& lexicon, std::vector<ChannelCandidate> beam,
        std::span<const Point> points, std::span<const std::string> contextWords, std::span<const std::string> dynamicWords,
        double gate, const std::function<bool()>& cancel) {
    if (cancel && cancel()) return {};
    std::erase_if(beam, [&](const auto& c) { return lexicon.isBlocked(c.word); });
    std::unordered_set<std::string> known;
    for (const auto& c : beam) known.insert(c.word);
    auto add = [&](const std::string& word) {
        if (known.contains(word) || lexicon.characterCount(word) < 2 || lexicon.isBlocked(word)) return;
        if (auto cost = shapeCost(word, points, 4, 0); cost && *cost <= gate) { beam.push_back({word, *cost, 0}); known.insert(word); }
    };
    for (const auto& word : contextWords) { if (cancel && cancel()) return {}; add(word); }
    if (!points.empty()) {
        auto first = lettersNear(points.front(), 1.3, 3), last = lettersNear(points.back(), 1.3, 3);
        for (const auto& word : dynamicWords) if (!word.empty() && std::find(first.begin(), first.end(), std::uint8_t(word.front())) != first.end() &&
            std::find(last.begin(), last.end(), std::uint8_t(word.back())) != last.end()) { if (cancel && cancel()) return {}; add(word); }
        if (lexicon.packed) for (const auto& word : lexicon.packed->anchorWords(first, last, 40)) { if (cancel && cancel()) return {}; add(word); }
    }
    if (cancel && cancel()) return {};
    std::erase_if(beam, [&](const auto& c) { return c.cost > gate; }); return beam;
}
std::vector<RankedRow> rankGlide(const GenerationLexicon& lexicon, std::span<const ChannelCandidate> rows,
        std::span<const double> language, std::span<const double> safety, double sigma, std::span<const std::uint8_t> dwell) {
    if (rows.size() != language.size() || rows.size() != safety.size()) throw std::invalid_argument("invalid glide score shape");
    std::vector<RankedRow> out;
    for (std::size_t i = 0; i < rows.size(); ++i) {
        const auto& c = rows[i]; double bonus = 0;
        if (!dwell.empty()) for (std::size_t j = 1; j < c.word.size(); ++j)
            if (c.word[j] == c.word[j - 1] && std::find(dwell.begin(), dwell.end(), std::uint8_t(c.word[j])) != dwell.end()) bonus += 1;
        auto frequency = lexicon.logFrequency(c.word).value_or(0);
        auto score = -c.cost / sigma + 0.6 * language[i] + 0.10 * frequency - safety[i] + 0.35 * bonus;
        out.push_back({c, c.word, safety[i], language[i], score, {}});
    }
    std::stable_sort(out.begin(), out.end(), [](const auto& a, const auto& b) { return a.score > b.score; }); return out;
}
std::vector<std::string> dynamicGlideWords(const CountRows& supplementary, const CountRows& personal, std::size_t limit) {
    std::unordered_map<std::string, std::int64_t> merged;
    for (const auto& [word, count] : supplementary) merged[word] = count;
    for (const auto& [word, count] : personal) merged[word] = std::max(merged[word], count + 100);
    CountRows rows(merged.begin(), merged.end());
    std::sort(rows.begin(), rows.end(), [](const auto& a, const auto& b) { return a.second == b.second ? a.first < b.first : a.second > b.second; });
    std::vector<std::string> out; for (const auto& [word, count] : rows) { (void)count; if (out.size() >= limit) break; out.push_back(word); } return out;
}
} // namespace kb
