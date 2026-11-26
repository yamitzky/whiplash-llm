package com.yamitzky.whiplash.android

import android.content.ContentResolver
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.net.Uri
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.math.max

/** 入力に付けたもの。テキストは本文に、画像はロールの画像入力方式に従って画像か OCR の文字になる。 */
sealed class Attachment {
    abstract val id: Long

    data class Text(override val id: Long, val text: String) : Attachment()

    class Image(override val id: Long, val bitmap: Bitmap, val jpeg: ByteArray) : Attachment() {
        val preview: ImageBitmap = bitmap.asImageBitmap()
    }
}

object ImageAttachments {
    /** 長い辺をこの大きさまで縮める。写真をそのまま送ると数 MB の Base64 になり、送信も OCR も遅くなるため。 */
    private const val MAX_SIDE = 2048

    /** ImageDecoder は EXIF の向きを反映して読むので、縦に撮った写真が横倒しで送られない。 */
    suspend fun load(resolver: ContentResolver, uri: Uri, id: Long): Attachment.Image = withContext(Dispatchers.IO) {
        val bitmap = ImageDecoder.decodeBitmap(ImageDecoder.createSource(resolver, uri)) { decoder, info, _ ->
            val longest = max(info.size.width, info.size.height)
            if (longest > MAX_SIDE) {
                val scale = MAX_SIDE.toFloat() / longest
                decoder.setTargetSize((info.size.width * scale).toInt(), (info.size.height * scale).toInt())
            }
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        }
        val jpeg = ByteArrayOutputStream().use { out ->
            bitmap.compress(Bitmap.CompressFormat.JPEG, 90, out)
            out.toByteArray()
        }
        Attachment.Image(id, bitmap, jpeg)
    }
}

/** ロールの画像入力方式が OCR のときに使う。日本語と英語の両方を読む ML Kit の日本語モデル。 */
object Ocr {
    private val recognizer by lazy { TextRecognition.getClient(JapaneseTextRecognizerOptions.Builder().build()) }

    suspend fun recognize(bitmap: Bitmap): String = suspendCancellableCoroutine { cont ->
        recognizer.process(InputImage.fromBitmap(bitmap, 0))
            .addOnSuccessListener { cont.resume(it.text) }
            .addOnFailureListener { cont.resumeWithException(it) }
    }
}
