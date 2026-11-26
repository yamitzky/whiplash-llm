package com.yamitzky.whiplash.android

import android.app.Application

class WhiplashApplication : Application() {
    /** 入力画面、設定画面、タイルが同じ保存先とプロバイダーを使うよう、プロセスに 1 つだけ作る。 */
    val container: AppContainer by lazy { AppContainer(this) }
}
