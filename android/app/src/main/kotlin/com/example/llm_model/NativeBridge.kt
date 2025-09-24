package com.example.llm_model
object NativeBridge {
    init { System.loadLibrary("llama_android") }
    external fun isAlive(): String
}
