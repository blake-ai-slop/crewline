# Màn hình mẫu SAI (v16)
Test cho bộ phủ định ghi cứng (tests/CrewAssist.Tests.ps1): gửi một tin rồi màn sau là màn ở đây ⇒ crew không Enter/Tab, không báo OK.
Gồm: hộp xin duyệt Claude/Codex, 'Allow command', hộp duyệt vẽ trên ô, ô có chữ gõ dở, hội thoại cũ + ô trống, hộp thoại lạ.
Dựng từ fixture thật `paste-v16/` (Claude 2.1.329, Codex 0.171). Thêm màn hình sai mới ⇒ thêm file .txt (test đếm số file).
(v16 assist-nolearn: crew không còn học mẫu nên bộ này không còn dùng lúc chạy, chỉ còn là test.)
