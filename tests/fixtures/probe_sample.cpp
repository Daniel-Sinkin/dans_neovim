namespace probe_sample
{
auto add(int lhs, int rhs) -> int
{
    return lhs + rhs;
}

struct Label
{
    int value;
};

auto to_string(const Label& label) -> const char*
{
    return label.value == 7 ? "seven" : "other";
}

auto touch(int& value) -> void
{
    value += 1;
}
}  // namespace probe_sample
