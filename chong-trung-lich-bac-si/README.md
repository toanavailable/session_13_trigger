# Chống trùng lịch bác sĩ

Xây dựng cơ chế tự động chặn lỗi "Double-booking" (một bác sĩ bị xếp 2 ca khám trùng giờ) ngay tại tầng Database, áp dụng cho cả thêm lịch mới và dời lịch cũ.

## 1. Đề bài

- **Bài toán:** mọi giao dịch gây trùng lịch bác sĩ phải bị từ chối với lỗi `"Lỗi: Bác sĩ đã có lịch hẹn vào khung giờ này"`.
- **Phạm vi:** áp dụng cho cả `INSERT` (thêm lịch mới) và `UPDATE` (dời lịch cũ).
- **Ngoại lệ 1:** khung giờ của ca khám đã hủy (`status = 'Cancelled'`) được tính là giờ trống, phải cho phép xếp lịch mới vào.
- **Ngoại lệ 2:** khi cập nhật thông tin của chính ca khám đó (VD đổi `'Pending'` sang `'Completed'`), hệ thống không được coi ca này trùng giờ với chính nó.

Cấu trúc bảng và dữ liệu mẫu (trong `chong_trung_lich.sql`). Mỗi ca khám được xác định bởi giờ bắt đầu `appointment_date`; hai ca trùng nhau khi cùng bác sĩ và cùng giờ bắt đầu.

```sql
CREATE TABLE Doctors (
    doctor_id   INT PRIMARY KEY,
    doctor_name VARCHAR(100) NOT NULL
);

CREATE TABLE Appointments (
    appointment_id   INT AUTO_INCREMENT PRIMARY KEY,
    doctor_id        INT          NOT NULL,
    patient_name     VARCHAR(100) NOT NULL,
    appointment_date DATETIME     NOT NULL,
    status           VARCHAR(20)  NOT NULL DEFAULT 'Pending',
    CONSTRAINT fk_appt_doctor FOREIGN KEY (doctor_id) REFERENCES Doctors (doctor_id),
    INDEX idx_appt_doctor_date (doctor_id, appointment_date)
);

INSERT INTO Doctors (doctor_id, doctor_name) VALUES
    (1, 'BS. Tran Minh'),
    (2, 'BS. Pham Lan');

INSERT INTO Appointments (doctor_id, patient_name, appointment_date, status) VALUES
    (1, 'Nguyen Van A', '2026-12-01 08:00:00', 'Pending'),
    (1, 'Tran Thi B',   '2026-12-01 09:00:00', 'Cancelled'),
    (2, 'Le Hoang C',   '2026-12-01 08:00:00', 'Pending');
```

## 2. Phân tích kỹ thuật

### Số lượng Trigger, sự kiện và thời điểm

MySQL không cho một Trigger lắng nghe nhiều sự kiện, nên cần **2 Trigger** trên bảng `Appointments`:

| Trigger | Sự kiện | Thời điểm | Lý do |
|---|---|---|---|
| `trg_appointments_before_insert_double_booking` | `INSERT` | `BEFORE` | Chặn lịch mới trùng giờ trước khi được ghi vào bảng |
| `trg_appointments_before_update_double_booking` | `UPDATE` | `BEFORE` | Chặn việc dời lịch (đổi giờ hoặc đổi bác sĩ) sang khung giờ đã có ca |

Phải dùng `BEFORE` vì việc kiểm tra cần diễn ra trước khi dữ liệu sai được ghi. Nếu dùng `AFTER`, lúc Trigger chạy dòng mới đã nằm trong bảng và truy vấn kiểm tra sẽ tìm thấy chính nó.

### Mệnh đề WHERE xử lý 2 ngoại lệ

```sql
WHERE a.doctor_id        = NEW.doctor_id        -- cùng bác sĩ
  AND a.appointment_date = NEW.appointment_date -- cùng khung giờ
  AND a.status          <> 'Cancelled'          -- Ngoại lệ 1: bỏ qua ca đã hủy
  AND a.appointment_id  <> NEW.appointment_id   -- Ngoại lệ 2: bỏ qua chính dòng đang cập nhật (chỉ ở UPDATE)
```

- **Ngoại lệ 1:** điều kiện `a.status <> 'Cancelled'` loại các ca đã hủy khỏi phép so sánh, nên khung giờ đó được tính là trống.
- **Ngoại lệ 2:** khi `UPDATE`, dòng đang sửa vẫn còn trong bảng với cùng `doctor_id` và `appointment_date`. Điều kiện `a.appointment_id <> NEW.appointment_id` loại chính nó ra. Ở `INSERT` không cần điều kiện này vì dòng mới chưa có trong bảng, và với `AUTO_INCREMENT` thì `NEW.appointment_id` trong `BEFORE INSERT` vẫn bằng 0.
- **Lịch mới đang `'Cancelled'`:** bản thân nó không chiếm giờ nên Trigger bỏ qua kiểm tra (`NEW.status <> 'Cancelled'`). Nhờ vậy thao tác hủy một ca luôn được phép.
- **Index `(doctor_id, appointment_date)`:** truy vấn kiểm tra chạy mỗi lần thêm hoặc sửa lịch, nên index giúp nó tìm nhanh thay vì quét toàn bảng.

## 3. Triển khai mã nguồn

```sql
DELIMITER //

CREATE TRIGGER trg_appointments_before_insert_double_booking
BEFORE INSERT ON Appointments
FOR EACH ROW
BEGIN
    IF NEW.status <> 'Cancelled' AND EXISTS (
        SELECT 1
        FROM Appointments AS a
        WHERE a.doctor_id        = NEW.doctor_id
          AND a.appointment_date = NEW.appointment_date
          AND a.status          <> 'Cancelled'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi: Bác sĩ đã có lịch hẹn vào khung giờ này';
    END IF;
END //

CREATE TRIGGER trg_appointments_before_update_double_booking
BEFORE UPDATE ON Appointments
FOR EACH ROW
BEGIN
    IF NEW.status <> 'Cancelled' AND EXISTS (
        SELECT 1
        FROM Appointments AS a
        WHERE a.doctor_id        = NEW.doctor_id
          AND a.appointment_date = NEW.appointment_date
          AND a.status          <> 'Cancelled'
          AND a.appointment_id  <> NEW.appointment_id
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi: Bác sĩ đã có lịch hẹn vào khung giờ này';
    END IF;
END //

DELIMITER ;
```

Trigger được phép **đọc** (`SELECT`) chính bảng đang gắn Trigger; MySQL chỉ cấm **sửa** bảng đó bên trong Trigger.

## 4. Kiểm thử nghiệm thu

```sql
-- Kịch bản 1: khung giờ hoàn toàn trống
INSERT INTO Appointments (doctor_id, patient_name, appointment_date) VALUES (1, 'Pham Thu D', '2026-12-01 10:00:00');

-- Kịch bản 2: khung giờ đang có ca 'Pending' (ca của Pham Thu D vừa thêm)
INSERT INTO Appointments (doctor_id, patient_name, appointment_date) VALUES (1, 'Hoang Van F', '2026-12-01 10:00:00');

-- Kịch bản 3: khung giờ đang có ca 'Cancelled'
INSERT INTO Appointments (doctor_id, patient_name, appointment_date) VALUES (1, 'Vo Thanh E', '2026-12-01 09:00:00');

-- Kịch bản 4: đổi trạng thái chính ca khám đó
UPDATE Appointments SET status = 'Completed' WHERE appointment_id = 1;
```

| Kịch bản | Thao tác | Kết quả |
|---|---|---|
| 1 | BS 1 lúc 10:00 (trống) | Thành công |
| 2 | BS 1 lúc 10:00 (đã có ca `Pending`) | Bị chặn: `Error Code: 1644. Lỗi: Bác sĩ đã có lịch hẹn vào khung giờ này` |
| 3 | BS 1 lúc 09:00 (chỉ có ca `Cancelled`) | Thành công |
| 4 | Ca id 1: `Pending` → `Completed` | Thành công, không bị coi là trùng với chính nó |
| Bổ sung | Dời ca id 3 sang BS 1 lúc 08:00 | Bị chặn (ca id 1 vẫn chiếm giờ dù đã `Completed`) |

Kịch bản 2 báo lỗi nên được đặt cuối file `.sql`; kịch bản bổ sung để dạng comment, chạy riêng.

Bảng `Appointments` sau kịch bản 1, 3, 4:

| appointment_id | doctor_id | patient_name | appointment_date | status |
|---|---|---|---|---|
| 1 | 1 | Nguyen Van A | 2026-12-01 08:00:00 | Completed |
| 2 | 1 | Tran Thi B | 2026-12-01 09:00:00 | Cancelled |
| 5 | 1 | Vo Thanh E | 2026-12-01 09:00:00 | Pending |
| 4 | 1 | Pham Thu D | 2026-12-01 10:00:00 | Pending |
| 3 | 2 | Le Hoang C | 2026-12-01 08:00:00 | Pending |
