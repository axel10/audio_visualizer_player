package com.example.audio_visualizer_player_example

import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity(){
    init {
        System.loadLibrary("audio_visualizer_player")
    }
}
