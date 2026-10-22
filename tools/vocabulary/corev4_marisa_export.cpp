// Export the static ordered trigrams in a decrypted CoreV4 v4 context tail.
// Link this small reader against the same CoreV4 library used by the engine.
#include <iostream>
#include <string>
#include "trie.h"

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    marisa::Trie trie;
    if (trie.load(argv[1]) != ATXSuccess || !trie.num_keys()) return 3;
    std::cerr << trie.num_keys() << ' ' << trie.io_size() << '\n';
    marisa::Agent agent;
    agent.set_query("");
    while (trie.predictive_search(agent)) {
        std::cout << agent.key().id() << '\t'
                  << std::string(agent.key().ptr(), agent.key().length()) << '\n';
    }
}
