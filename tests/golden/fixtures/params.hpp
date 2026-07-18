// param flip
void f(int x, const Foo& ro, Bar& rw, Baz* p);
auto g(SizeLike auto n) -> void;
auto h(std::string_view s, std::vector<int>& v) -> usize;
auto def_arg(int n = 0, float scale = 1.0f) -> void;
