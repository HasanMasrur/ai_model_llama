package com.example.llm_model

object NativeBridge {
    init { System.loadLibrary("llama_android") } // wrapper .so
    external fun isAlive(): String
}
