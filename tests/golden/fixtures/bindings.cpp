void use(int x)
{
    auto a = compute();
    const auto b = compute();
    auto& r = a;
    const auto& cr = a;
    auto* p = &x;
    const auto* cp = get_ptr();
    const auto* version = glfwGetVersionString();
    auto&& fwd = make();
    throw std::runtime_error("oops");
}
