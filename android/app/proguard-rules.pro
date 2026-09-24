# android/app/proguard-rules.pro
#
# Release builds are minified by R8: Flutter's Gradle plugin turns
# isMinifyEnabled on for `release` and adds THIS file automatically when it
# exists (FlutterPlugin.kt), so build.gradle.kts does not reference it.
#
# Razorpay's checkout SDK (razorpay_flutter) reaches its callbacks by
# reflection — `onPaymentSuccess` / `onPaymentError` and the JS bridge inside
# its WebView. R8 renaming or inlining them makes the sheet open and then never
# report back: the owner pays and the app hears nothing. Razorpay's documented
# keep rules:
-keepattributes *Annotation*
-dontwarn com.razorpay.**
-keep class com.razorpay.** { *; }
-optimizations !method/inlining/
-keepclasseswithmembers class * { public void onPayment*(...); }
