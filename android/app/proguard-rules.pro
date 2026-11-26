# Ktor は使うエンジンを ServiceLoader で探すので、名前が変わると OkHttp のエンジンが見つからない。
-keep class io.ktor.client.engine.okhttp.** { *; }
-dontwarn org.slf4j.**

# ML Kit は内部で部品をコンポーネントの登録から取り出す。R8 で最適化すると取り出した値が null になり、
# Gemini Nano (Generation.getClient) と OCR (TextRecognizer) がどちらも NullPointerException になった
# (2026-11-27、Pixel 11 のリリースビルドで確認)。ML Kit のクラスは最適化しない。
-keep class com.google.mlkit.** { *; }
