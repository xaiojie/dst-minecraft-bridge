package dev.jay.dstmc.client.mixin;
import com.mojang.blaze3d.platform.Window;
import dev.jay.dstmc.client.PassthroughWindow;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.*;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
@Mixin(Window.class)
public abstract class WindowCreateMixin {
    @Inject(method="<init>",at=@At(value="INVOKE",target="Lorg/lwjgl/glfw/GLFW;glfwCreateWindow(IILjava/lang/CharSequence;JJ)J",shift=At.Shift.BEFORE))
    private void transparentFramebuffer(CallbackInfo ci){PassthroughWindow.creationHints();}
}
