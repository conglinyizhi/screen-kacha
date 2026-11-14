///|
/// 本机屏幕快照服务。
///
/// 采集走 spectacle，HTTP 层用 crescent。对外只有只读接口：
/// `/snapshot-{宽度}.{jpg|webp}` 取一帧，`/health` 看状态，`/skill.md` 看说明。
