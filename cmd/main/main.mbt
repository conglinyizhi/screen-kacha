///|
async fn main {
  let port = 18940
  let shot = "/tmp/screenstream-mb-latest.jpg"
  let store = @store.Store::new(shot~)
  let app = @store.build_app(store, port)
  println("screenstream-mb v0.1 监听 0.0.0.0:\{port}")
  app.serve(port~)
}
