// nesting.hpp -- eye-reviewed scenario: deep template nesting and member
// alignment blocks with wildly different widths. Arrays collapse at every
// depth, pointer members carry no mut, the reference member does, and the
// constexpr constants split into their own group.
#pragma once
// StdLib
#include <array>
#include <expected>
#include <memory>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>
//
namespace dans::vk {

struct FrameResources
{
    static constexpr u32 k_max_frames{2};
    static constexpr u32 k_max_sets{16};
    std::array<std::array<f32, 4>, 4> transform{};
    std::array<std::optional<u32>, 8> family_indices{};
    std::vector<std::array<f32, 3>> positions{};
    std::unordered_map<std::string, std::vector<std::pair<int, int>>> lookup{};
    std::unique_ptr<Device, DeviceDeleter> device{};
    std::optional<std::string> debug_name{};
    std::expected<std::vector<u32>, Error> spirv{};
    Device* raw_device{};
    const Instance* instance{};
    Queue& graphics_queue;
};

auto build_lut() -> void
{
    constexpr usize k_w{4};
    constexpr usize k_h{2};
    std::array<std::array<Color, 4>, 2> lut{};
    const auto first = lut[0][0];
    auto& row = lut[0];
    for (const auto& cell : row)
    {
        use(cell);
    }
    if (const auto found = lookup.find(key); found != lookup.end())
    {
        use(*found);
    }
}

} // namespace dans::vk
