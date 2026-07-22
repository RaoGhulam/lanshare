# ML Kit / mobile_scanner — keep component registrars and their no-arg constructors
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_barcode.** { *; }
-keep class com.google.android.odml.** { *; }
-dontwarn com.google.mlkit.**
-dontwarn com.google.android.gms.**

# Keep anything implementing ML Kit's component discovery interface
-keep class * implements com.google.mlkit.common.internal.ComponentRegistrar { *; }
