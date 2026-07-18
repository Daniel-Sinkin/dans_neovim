void use()
{
    /* Platform-specific calling convention macros.
     *
     * VKAPI_ATTR - Placed before the return type in function declarations.
     * VKAPI_CALL - Placed after the return type in function declarations.
     * VKAPI_PTR  - Placed between the '(' and '*' in function pointer types.
     *
     * Function declaration:  VKAPI_ATTR void VKAPI_CALL vkCommand(void);
     * Function pointer type: typedef void (VKAPI_PTR *PFN_vkCommand)(void);
     */
    glfwInit();
}
