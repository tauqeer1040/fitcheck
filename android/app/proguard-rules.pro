# Release shrinking (R8 + shrinkResources) keep-list. Flutter's engine and
# every plugin bridge below are touched reflectively / from Dart, so R8
# must not strip or rename them. Everything else is fair game.
-keep class io.flutter.** { *; }
# image_picker (photo picker + camera intent).
# Embedded system photo grid (androidx.photopicker, debug lab only).
-keep class androidx.photopicker.** { *; }
# TFLite interpreter: only the runtime-resolved entry points must survive.
# (A blanket org.tensorflow keep-all was retaining dead wrapper code.)
# NB: 2.x calls the buffer class `Tensor`, not `LiteTensor`.
-keep class org.tensorflow.lite.Interpreter { *; }
-keep class org.tensorflow.lite.DelegatedInterpreter { *; }
-keep class org.tensorflow.lite.Tensor { *; }
-keep class org.tensorflow.lite.TensorFlowLite { *; }
-keep interface org.tensorflow.lite.Interpreter$Delegate { *; }
# ML Kit segmentation (runs through Play services APIs).
# ML Kit's own AARs ship NO consumer rules, so these must be kept here —
# but only the classes ML Kit actually reflects on. play-services-basement
# and play-services-base already ship their own consumer rules, so a blanket
# com.google.android.gms.** keep is redundant and was pinning ~2.4 MB of
# Firebase measurement / auth / stats internals that nothing here calls.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.common.internal.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_mediapipe.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_segmentation.** { *; }
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
