# Kiểm soát trạng thái lịch khám

Phân tích lỗi của Trigger `PreventStatusRevert` (kiểm tra trên `NEW` thay vì `OLD`) khiến hệ thống chặn cả những cập nhật hợp lệ, và viết lại Trigger để chỉ khóa các lịch khám đã `'Completed'`.

## 1. Đề bài

- **Bối cảnh:** khi hồ sơ bệnh nhân đã khám xong (`status = 'Completed'`), dữ liệu được xem là "đóng sổ" để kế toán tính lương.
- **Quy tắc hệ thống:** tuyệt đối không được thay đổi trạng thái của lịch khám đã `'Completed'`.
- **Mã nguồn hiện tại:** không lỗi cú pháp nhưng sai logic, chặn cả các cập nhật hợp lệ.

```sql
DELIMITER //
CREATE TRIGGER PreventStatusRevert
BEFORE UPDATE ON Appointments
FOR EACH ROW
BEGIN
    -- Lỗi logic: dùng NEW thay vì OLD khiến toàn bộ hệ thống bị "tê liệt"
    IF NEW.status = 'Completed' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi: Không được phép thao tác trên lịch khám này!';
    END IF;
END //
DELIMITER ;
```

File `kiem_soat_trang_thai.sql` tự tạo bảng `Appointments` với 3 lịch mẫu:

```sql
CREATE TABLE Appointments (
    appointment_id   INT PRIMARY KEY,
    patient_name     VARCHAR(100) NOT NULL,
    appointment_date DATETIME     NOT NULL,
    status           VARCHAR(20)  NOT NULL DEFAULT 'Pending',
    note             VARCHAR(255)
);

INSERT INTO Appointments (appointment_id, patient_name, appointment_date, status, note) VALUES
    (103, 'Le Hoang C', '2026-11-10 08:00:00', 'Completed', 'Đã khám, đã thu tiền'),
    (104, 'Pham Thu D', '2026-11-19 09:00:00', 'Pending',   NULL),
    (105, 'Vo Thanh E', '2026-11-25 10:30:00', 'Pending',   NULL);
```

## 2. Phần A – Phân tích

### Tái hiện lỗi

```sql
UPDATE Appointments SET status = 'Completed' WHERE appointment_id = 104;
```

Kết quả với Trigger cũ:

```
Error Code: 1644. Lỗi: Không được phép thao tác trên lịch khám này!
```

Bác sĩ không thể chốt ca khám 104 dù đây là thao tác hợp lệ (`Pending` → `Completed`). Lệnh này được để dạng comment trong file `.sql` vì lỗi sẽ dừng việc chạy cả script.

### Nên dùng OLD hay NEW?

Phải dùng **`OLD`**. Câu hỏi "lịch này **đã** hoàn thành chưa" là câu hỏi về dữ liệu đang lưu trong bảng **trước** khi cập nhật, tức `OLD.status`. Còn `NEW.status` là giá trị người dùng muốn ghi vào, nên điều kiện `NEW.status = 'Completed'` lại chặn đúng hành động chốt ca hợp lệ, trong khi cho phép kéo lịch đã `Completed` về `Pending` (vì `NEW.status = 'Pending'`).

## 3. Phần B – Sửa chữa mã nguồn

```sql
DROP TRIGGER IF EXISTS PreventStatusRevert;

DELIMITER //

CREATE TRIGGER PreventStatusRevert
BEFORE UPDATE ON Appointments
FOR EACH ROW
BEGIN
    -- Kiểm tra trạng thái ĐANG LƯU trong bảng: lịch đã Completed là "đóng sổ"
    IF OLD.status = 'Completed' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi: Lịch khám đã hoàn thành (đóng sổ), không được phép thay đổi!';
    END IF;
END //

DELIMITER ;
```

Điều kiện `OLD.status = 'Completed'` khóa toàn bộ dòng đã đóng sổ, không riêng gì cột `status`: sửa ngày khám hay ghi chú của lịch đã hoàn thành cũng bị chặn, đúng tinh thần dữ liệu đã chốt cho kế toán. Trigger dùng `BEFORE` để chặn trước khi dữ liệu bị ghi.

## 4. Kiểm thử

```sql
UPDATE Appointments SET status = 'Completed' WHERE appointment_id = 104;  -- Test 1
UPDATE Appointments SET status = 'Cancelled' WHERE appointment_id = 105;  -- Test 2
UPDATE Appointments SET status = 'Pending'   WHERE appointment_id = 103;  -- Test 3
```

| Test | Thao tác | Trigger cũ | Trigger mới |
|---|---|---|---|
| 1 | 104: `Pending` → `Completed` | **Bị chặn oan** | Thành công |
| 2 | 105: `Pending` → `Cancelled` | Thành công | Thành công |
| 3 | 103: `Completed` → `Pending` | **Cho qua (lỗi)** | Bị chặn: `Lỗi: Lịch khám đã hoàn thành (đóng sổ), không được phép thay đổi!` |

Bảng sau Test 1 và Test 2:

| appointment_id | patient_name | status |
|---|---|---|
| 103 | Le Hoang C | Completed |
| 104 | Pham Thu D | Completed |
| 105 | Vo Thanh E | Cancelled |
