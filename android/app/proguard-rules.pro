# Release shrinking (R8 + shrinkResources) keep-list. Flutter's engine and
# every plugin bridge below are touched reflectively / from Dart, so R8
# must not strip or rename them. Everything else is fair game.
-keep class io.flutter.** { *; }
# Purchases / RevenueCat.
-keep class com.revenuecat.** { *; }
# Gallery / media access (photo_manager).
-keep class com.fluttercandies.** { *; }
# TFLite interpreter (model ops resolve at runtime).
-keep class org.tensorflow.** { *; }
# ML Kit segmentation (runs through Play services APIs).
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.** { *; }
# Notifications, in-app review prompt, home widgets.
-keep class com.dexterous.** { *; }
-keep class dev.britannio.** { *; }
-keep class es.antonborri.** { *; }
# Referenced by the Flutter embedding's deferred-components path, which the
# app never uses (no deferred components) — silence, don't keep.
-dontwarn com.google.android.play.core.splitcompat.**
-dontwarn com.google.android.play.core.splitinstall.**
-dontwarn com.google.android.play.core.tasks.**
-keepattributes *Annotation*, Signature, Exceptions, InnerClasses
