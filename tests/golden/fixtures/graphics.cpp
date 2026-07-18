void use()
{
    glClear(GL_COLOR_BUFFER_BIT);
    handle(VK_SUCCESS);
    pick(VK_KHR_SURFACE_EXTENSION_NAME);
    VmaAllocator alloc;
    vmaCreateBuffer(alloc);
    use(VMA_MEMORY_USAGE_GPU_ONLY);
    _GLFWwindow mon;
    _glfwInputKey(mon);
}
