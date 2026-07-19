// AgentRuntime を import すれば、ワーカー実装に最低限必要な型が揃うようにする。
//
// A2AServer / A2AInProcess は再輸出しない。サーバ実装・インプロセス配線を使う側は
// 自分で swift-a2a への依存を宣言すること（暗黙の可視性に寄りかかると、
// 依存グラフに現れない結合が育つ）。
@_exported import AgentLoopKit
@_exported import A2ACore
@_exported import LLMClient
@_exported import LLMTool
