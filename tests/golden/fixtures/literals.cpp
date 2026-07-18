// header: VkResult std::vector glfwInit in a line comment stay raw
#pragma once
//
namespace dans::test
{
const char* names = "VkResult glfwInit std::vector stay verbatim";
/* block: VkResult std::vector glfwPollEvents stay raw too */
inline auto resolve() -> void
{
    const auto a = vkCreateInstance(&info);
    VkResult status = check();
    const auto* fn = glfwGetProcAddress("vkGetDeviceProcAddr");
    char marker = 'V';
}
}  // namespace dans::test
