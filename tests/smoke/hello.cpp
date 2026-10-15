#include <iostream>
#include <string>
#include <vector>

int main()
{
    std::vector<std::string> words = {"hello", "from", "morphos-cross"};
    for (const auto &word : words) std::cout << word << ' ';
    std::cout << '\n';
    return 0;
}
