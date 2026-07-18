class Platform
{
  public:
    Platform() = default;
    ~Platform() = default;
    Platform(const Platform&) = delete;
    def operator=(const Platform&) -> Platform& = delete;
    Platform(Platform&&) = delete;
    def operator=(Platform&&) -> Platform& = delete;
};

struct Widget
{
    Widget(const Widget&) = default;
    Widget& operator=(const Widget&) = default;
    Widget(Widget&&) noexcept = default;
    ~Widget() = default;
};
