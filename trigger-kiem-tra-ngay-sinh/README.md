# Tạo Trigger kiểm tra tính hợp lệ của ngày sinh

Tạo Trigger `tg_check_birthday_before_insert` trên bảng `student` để chặn sinh viên có ngày sinh lớn hơn hoặc bằng ngày hiện tại.

## 1. Đề bài

- **Mục tiêu:**
  - áp dụng đúng cú pháp tạo Trigger;
  - dùng biến tạm `NEW` để đọc dữ liệu trước khi ghi;
  - dùng `SIGNAL` để ném lỗi và chặn dữ liệu sai.
- **Yêu cầu logic:** sinh viên không được có ngày sinh **lớn hơn hoặc bằng** ngày hiện tại. Lấy ngày sinh bằng `NEW.birthday`, lấy ngày hôm nay bằng `CURRENT_DATE`.
- **Thông báo lỗi:** dùng `SIGNAL SQLSTATE '45000'` với nội dung `"Lỗi hệ thống: Ngày sinh không hợp lệ, phải nhỏ hơn ngày hôm nay!"`.

## 2. Giải pháp

### Bước 1 – Chuẩn bị bảng dữ liệu

```sql
CREATE DATABASE IF NOT EXISTS trigger_practice CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE trigger_practice;

CREATE TABLE student (
    id       INT AUTO_INCREMENT PRIMARY KEY,
    name     VARCHAR(100) NOT NULL,
    birthday DATE         NOT NULL,
    phone    VARCHAR(15)
);
```

### Bước 2 đến 4 – Tạo Trigger

```sql
DELIMITER //

CREATE TRIGGER tg_check_birthday_before_insert
BEFORE INSERT ON student
FOR EACH ROW
BEGIN
    -- Ngày sinh không được lớn hơn hoặc bằng ngày hiện tại
    IF NEW.birthday >= CURRENT_DATE() THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi hệ thống: Ngày sinh không hợp lệ, phải nhỏ hơn ngày hôm nay!';
    END IF;
END //

DELIMITER ;
```

- **`BEFORE INSERT`:** kiểm tra diễn ra trước khi dòng mới được ghi vào bảng; khi `SIGNAL` ném lỗi, lệnh `INSERT` bị hủy và dữ liệu sai không vào được bảng.
- **`NEW.birthday`:** với thao tác `INSERT`, chỉ có biến `NEW`, chứa ngày sinh của dòng sắp chèn.
- **Điều kiện `>=`:** dấu bằng giúp chặn cả trường hợp ngày sinh đúng bằng hôm nay, đúng yêu cầu "lớn hơn hoặc bằng".
- **`DELIMITER //`:** đổi dấu kết thúc lệnh để MySQL không hiểu nhầm các dấu `;` bên trong `BEGIN...END` là kết thúc lệnh `CREATE TRIGGER`; tạo xong thì trả lại `DELIMITER ;`.

## 3. Bước 5 – Kiểm tra dữ liệu

```sql
-- Trường hợp thành công
INSERT INTO student (name, birthday, phone)
VALUES ('Lê Thị C', '2000-01-01', '0912345678');

-- Trường hợp lỗi: ngày sinh đúng bằng hôm nay
INSERT INTO student (name, birthday, phone)
VALUES ('Trần Văn B', CURRENT_DATE(), '0987654321');
```

| Trường hợp | Dữ liệu | Kết quả |
|---|---|---|
| Thành công | Lê Thị C, sinh 01/01/2000 | Chèn thành công |
| Lỗi | Trần Văn B, sinh đúng ngày hôm nay | `Error Code: 1644. Lỗi hệ thống: Ngày sinh không hợp lệ, phải nhỏ hơn ngày hôm nay!` |

`SELECT * FROM student` sau 2 lệnh trên chỉ có 1 dòng, xác nhận Trần Văn B không được chèn:

| id | name | birthday | phone |
|---|---|---|---|
| 1 | Lê Thị C | 2000-01-01 | 0912345678 |

Trường hợp lỗi được đặt sau trường hợp thành công trong file `.sql`, vì lỗi sẽ dừng script.
