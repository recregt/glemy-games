// Thin WebSocket wrapper -- Gleam cannot express `new WebSocket()`,
// `.onmessage`/`.onopen`, or `.send()` itself. No decoding or game logic
// here: every message payload is handed to `on_message` as a raw string,
// decoded entirely on the Gleam side (game_breakout_multiplayer.gleam's
// own `server_message_decoder`).

export function wsConnect(url, onMessage, onOpen) {
  const socket = new WebSocket(url);
  socket.onmessage = (event) => onMessage(event.data);
  socket.onopen = () => onOpen();
  return socket;
}

export function wsSend(socket, text) {
  socket.send(text);
}
