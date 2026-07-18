void ui()
{
    ImGui::Begin("x");
    ImGui::Text("hi");
    set(IM_COL32(255, 0, 0, 255));
    IM_ASSERT(ptr);
    IM_STATIC_ASSERT(ok);
    IM_ASSERT_USER_ERROR(x);
    draw(ImVec2(), ImRect());
}
