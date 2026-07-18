// dans/gfx/color.hpp
//
#pragma once

#include "dans/linalg/linalg.hpp"
// Externals
#include "dans/dans-core/types.hpp"
// StdLib
#include <algorithm>
#include <array>
//

namespace dans::gfx
{
using dans::linalg::Vec4;

struct Color
{
    std::array<f32, 4> channels{1.0f, 1.0f, 1.0f, 1.0f};

    constexpr Color() noexcept = default;
    constexpr Color(f32 r, f32 g, f32 b, f32 a = 1.0f) noexcept : channels{r, g, b, a}
    {
    }

    // clang-format off
    [[nodiscard]] constexpr auto data()       noexcept -> f32*       { return channels.data(); }
    [[nodiscard]] constexpr auto data() const noexcept -> const f32* { return channels.data(); }

    [[nodiscard]] constexpr auto r()          noexcept -> f32&       { return channels[0]; }
    [[nodiscard]] constexpr auto g()          noexcept -> f32&       { return channels[1]; }
    [[nodiscard]] constexpr auto b()          noexcept -> f32&       { return channels[2]; }
    [[nodiscard]] constexpr auto a()          noexcept -> f32&       { return channels[3]; }

    [[nodiscard]] constexpr auto r()    const noexcept -> f32        { return channels[0]; }
    [[nodiscard]] constexpr auto g()    const noexcept -> f32        { return channels[1]; }
    [[nodiscard]] constexpr auto b()    const noexcept -> f32        { return channels[2]; }
    [[nodiscard]] constexpr auto a()    const noexcept -> f32        { return channels[3]; }
    // clang-format on

    static const Color black;
    static const Color white;
    static const Color red;
    static const Color green;
    static const Color blue;
    static const Color yellow;
    static const Color cyan;
    static const Color magenta;
    static const Color orange;
    static const Color gray;
};

// clang-format off
inline constexpr Color Color::black  {0.0f, 0.0f, 0.0f, 1.0f};
inline constexpr Color Color::white  {1.0f, 1.0f, 1.0f, 1.0f};
inline constexpr Color Color::red    {1.0f, 0.0f, 0.0f, 1.0f};
inline constexpr Color Color::green  {0.0f, 1.0f, 0.0f, 1.0f};
inline constexpr Color Color::blue   {0.0f, 0.0f, 1.0f, 1.0f};
inline constexpr Color Color::yellow {1.0f, 1.0f, 0.0f, 1.0f};
inline constexpr Color Color::cyan   {0.0f, 1.0f, 1.0f, 1.0f};
inline constexpr Color Color::magenta{1.0f, 0.0f, 1.0f, 1.0f};
inline constexpr Color Color::orange {1.0f, 0.5f, 0.0f, 1.0f};
inline constexpr Color Color::gray   {0.5f, 0.5f, 0.5f, 1.0f};
// clang-format on

struct ColorU8
{
    std::array<u8, 4> channels{255u, 255u, 255u, 255u};

    constexpr ColorU8() noexcept = default;
    constexpr ColorU8(u8 r, u8 g, u8 b, u8 a = 255u) noexcept : channels{r, g, b, a}
    {
    }

    // clang-format off
    [[nodiscard]] constexpr auto data()       noexcept -> u8*       { return channels.data(); }
    [[nodiscard]] constexpr auto data() const noexcept -> const u8* { return channels.data(); }

    [[nodiscard]] constexpr auto r()          noexcept -> u8&       { return channels[0]; }
    [[nodiscard]] constexpr auto g()          noexcept -> u8&       { return channels[1]; }
    [[nodiscard]] constexpr auto b()          noexcept -> u8&       { return channels[2]; }
    [[nodiscard]] constexpr auto a()          noexcept -> u8&       { return channels[3]; }

    [[nodiscard]] constexpr auto r()    const noexcept -> u8        { return channels[0]; }
    [[nodiscard]] constexpr auto g()    const noexcept -> u8        { return channels[1]; }
    [[nodiscard]] constexpr auto b()    const noexcept -> u8        { return channels[2]; }
    [[nodiscard]] constexpr auto a()    const noexcept -> u8        { return channels[3]; }
    // clang-format on
};

static_assert(sizeof(Color) == 4zu * sizeof(f32));
static_assert(sizeof(ColorU8) == 4zu * sizeof(u8));

[[nodiscard]] constexpr auto to_vec4(Color color) noexcept -> Vec4
{
    return Vec4{color.r(), color.g(), color.b(), color.a()};
}

[[nodiscard]] constexpr auto to_color(Vec4 value) noexcept -> Color
{
    return Color{value.r, value.g, value.b, value.a};
}

[[nodiscard]] constexpr auto to_color(ColorU8 color) noexcept -> Color
{
    constexpr auto inv_255 = 1.0f / 255.0f;
    return Color{
        static_cast<f32>(color.r()) * inv_255,
        static_cast<f32>(color.g()) * inv_255,
        static_cast<f32>(color.b()) * inv_255,
        static_cast<f32>(color.a()) * inv_255,
    };
}

[[nodiscard]] constexpr auto color_channel_to_u8(f32 value) noexcept -> u8
{
    const auto scaled = std::clamp(value, 0.0f, 1.0f) * 255.0f + 0.5f;
    return static_cast<u8>(scaled);
}

[[nodiscard]] constexpr auto to_color_u8(Color color) noexcept -> ColorU8
{
    return ColorU8{
        color_channel_to_u8(color.r()),
        color_channel_to_u8(color.g()),
        color_channel_to_u8(color.b()),
        color_channel_to_u8(color.a()),
    };
}

[[nodiscard]] constexpr auto with_alpha(Color color, f32 alpha) noexcept -> Color
{
    return Color{color.r(), color.g(), color.b(), alpha};
}

[[nodiscard]] constexpr auto mix_color(Color a, Color b, f32 t) noexcept -> Color
{
    const auto clamped_t = std::clamp(t, 0.0f, 1.0f);
    const auto inv_t = 1.0f - clamped_t;
    return Color{
        a.r() * inv_t + b.r() * clamped_t,
        a.g() * inv_t + b.g() * clamped_t,
        a.b() * inv_t + b.b() * clamped_t,
        a.a() * inv_t + b.a() * clamped_t,
    };
}

[[nodiscard]] constexpr auto luminance(Color color) noexcept -> f32
{
    return 0.299f * color.r() + 0.587f * color.g() + 0.114f * color.b();
}

[[nodiscard]] constexpr auto grayscale(Color color) noexcept -> Color
{
    const auto y = luminance(color);
    return Color{y, y, y, color.a()};
}

}  // namespace dans::gfx
