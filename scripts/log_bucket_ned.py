#!/usr/bin/env python3
r"""独立采集最终对准算法的数据；只打印日志，不发布目标或飞控指令。

在 deploy 仓库一键运行：
  ./scripts/run-bucket-logger.sh --target-id middle
持续采集；稳定时敲 y（无需回车），标记最近一条有效观测；Ctrl-C 结束。
没有稳定标记也保留全部观测。最终在桶正上方的标记可作为后续固定 NED 的参考。

每条 sample 打印 aircraft_ned、bucket_ned、bbox_center_px，并保留求解所需的
深度、内参、姿态、时间差。y 只是人工稳定标记，不自动判断是否已到桶正上方。
相机偏移必须与实际 0821auto.py 参数一致；默认 (-0.065, 0.033, 0.15) m。
脚本独立运行 YOLO；采集时无需再启动另一份深度检测器或自主控制任务。
"""

import argparse
from collections import deque
from contextlib import redirect_stdout
import json
import math
from pathlib import Path
import select
import signal
import sys
import termios
import threading
import time
import tty
import uuid

_print_lock = threading.Lock()
_log_file = None


def print_json(record):
    with _print_lock:
        line = json.dumps(record, ensure_ascii=False, allow_nan=False)
        if _log_file is not None:
            _log_file.write(line + '\n')
            _log_file.flush()
        print(line, flush=True)


class KeyboardMarkers:
    """捕获当前终端的 y；保留 Ctrl-C 行为，退出时恢复终端设置。"""

    def __init__(self, on_stable):
        self.on_stable = on_stable
        self.stop = threading.Event()
        self.stream = None
        self.saved = None
        self.thread = None

    def start(self):
        try:
            self.stream = open('/dev/tty', 'rb', buffering=0)
            self.saved = termios.tcgetattr(self.stream.fileno())
            tty.setcbreak(self.stream.fileno())
        except (OSError, termios.error) as exc:
            self.close()
            print(f'[bucket-log] 无交互终端，仍采集全部数据；无法捕获 y: {exc}',
                  file=sys.stderr, flush=True)
            return
        self.thread = threading.Thread(target=self.read_keys, daemon=True)
        self.thread.start()
        print('[bucket-log] 稳定时敲 y 标记当前样本，无需回车；Ctrl-C 结束。',
              file=sys.stderr, flush=True)

    def read_keys(self):
        while not self.stop.is_set():
            try:
                readable, _, _ = select.select([self.stream], [], [], 0.2)
                if not readable:
                    continue
                key = self.stream.read(1)
                if not key:
                    return
                if key in (b'y', b'Y'):
                    self.on_stable()
            except OSError:
                return

    def close(self):
        self.stop.set()
        if self.thread is not None:
            self.thread.join(timeout=0.5)
        if self.stream is not None:
            if self.saved is not None:
                try:
                    termios.tcsetattr(self.stream.fileno(), termios.TCSANOW, self.saved)
                except (OSError, termios.error):
                    pass
            self.stream.close()
            self.stream = None


def camera_to_ned(camera_xyz, aircraft_ned, rpy, offset):
    """与当前最终对准相同：cam -> FRD -> NED，Rz(yaw) Ry(pitch) Rx(roll)。"""
    x, y, z = camera_xyz
    x, y, z = y + offset[0], -x + offset[1], z + offset[2]
    roll, pitch, yaw = rpy
    cr, sr = math.cos(roll), math.sin(roll)
    cp, sp = math.cos(pitch), math.sin(pitch)
    cy, sy = math.cos(yaw), math.sin(yaw)
    y, z = cr * y - sr * z, sr * y + cr * z
    x, z = cp * x + sp * z, -sp * x + cp * z
    return [aircraft_ned[0] + cy*x - sy*y,
            aircraft_ned[1] + sy*x + cy*y, aircraft_ned[2] + z]


def choose_target(candidates):
    """同最终对准：有效深度、class 0、置信度优先，同分时接近图像中心。"""
    valid = [c for c in candidates if math.isfinite(c['confidence'])
             and math.isfinite(c['depth_m']) and c['depth_m'] > 0]
    return max(valid, key=lambda c: (c['confidence'], -c['center_distance_sq']),
               default=None)


def depth_scale(encoding):
    encoding = encoding.upper()
    if encoding in ('16UC1', 'MONO16'):
        return 0.001
    if encoding in ('32FC1', '64FC1'):
        return 1.0
    raise ValueError(f'不支持的深度编码: {encoding}')


def parser():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--weights', required=True, help='与最终对准相同的模型文件')
    p.add_argument('--target-id', default='bucket', help='同一个桶两段记录使用相同名称')
    p.add_argument('--output', help='额外保存 JSONL；一键启动时自动设置')
    p.add_argument('--conf', type=float, default=0.4, help='与检测器相同的置信度阈值')
    p.add_argument('--hz', type=float, default=5.0, help='最大采集/推理频率')
    p.add_argument('--depthcam-xoffset', type=float, default=-0.065)
    p.add_argument('--depthcam-yoffset', type=float, default=0.033)
    p.add_argument('--depthcam-zoffset', type=float, default=0.15)
    p.add_argument('--color-topic', default='/camera/camera/color/image_raw')
    p.add_argument('--depth-topic', default='/camera/camera/aligned_depth_to_color/image_raw')
    p.add_argument('--camera-info-topic', default='/camera/camera/color/camera_info')
    p.add_argument('--position-topic', default='/fmu/out/vehicle_local_position_v1')
    p.add_argument('--odometry-topic', default='/fmu/out/vehicle_odometry')
    return p


def main():
    p = parser()
    args, ros_args = p.parse_known_args()
    for key in ('conf', 'hz', 'depthcam_xoffset', 'depthcam_yoffset', 'depthcam_zoffset'):
        if not math.isfinite(getattr(args, key)):
            p.error(f'{key} 必须是有限数值')
    if args.hz <= 0 or not 0 <= args.conf <= 1:
        p.error('hz 必须大于 0，conf 必须在 0..1 之间')

    # --help 不依赖 ROS。其余依赖与现有深度相机检测环境相同。
    import numpy as np
    import rclpy
    from rclpy.node import Node
    from rclpy.qos import qos_profile_sensor_data
    from rclpy.callback_groups import MutuallyExclusiveCallbackGroup
    from rclpy.executors import MultiThreadedExecutor, ExternalShutdownException
    from px4_msgs.msg import VehicleLocalPosition, VehicleOdometry
    from sensor_msgs.msg import CameraInfo, Image
    import message_filters
    from cv_bridge import CvBridge
    from scipy.spatial.transform import Rotation
    from ultralytics import YOLO

    class BucketLogger(Node):
        def __init__(self):
            super().__init__('standalone_bucket_ned_logger')
            self.session = uuid.uuid4().hex
            self.bridge = CvBridge()
            self.offset = [args.depthcam_xoffset, args.depthcam_yoffset,
                           args.depthcam_zoffset]
            self.intrinsics = None
            self.attitude = None
            self.poses = deque(maxlen=800)
            self.pose_lock = threading.Lock()
            self.sample_lock = threading.Lock()
            self.latest_sample = None
            self.reset = None
            self.reference_start = None
            self.last_pose_time = None
            self.last_inference = -math.inf
            self.sequence = 0
            self.last_warning = {}
            with redirect_stdout(sys.stderr):
                self.model = YOLO(args.weights)
            group = MutuallyExclusiveCallbackGroup()
            self.pose_group = group
            self.create_subscription(VehicleLocalPosition, args.position_topic,
                                     self.on_position, qos_profile_sensor_data,
                                     callback_group=group)
            self.create_subscription(VehicleOdometry, args.odometry_topic,
                                     self.on_odometry, qos_profile_sensor_data,
                                     callback_group=group)
            self.create_subscription(CameraInfo, args.camera_info_topic,
                                     self.on_info, qos_profile_sensor_data)
            self.color_sub = message_filters.Subscriber(
                self, Image, args.color_topic, qos_profile=qos_profile_sensor_data)
            self.depth_sub = message_filters.Subscriber(
                self, Image, args.depth_topic, qos_profile=qos_profile_sensor_data)
            self.sync = message_filters.ApproximateTimeSynchronizer(
                [self.color_sub, self.depth_sub], queue_size=5, slop=0.04)
            self.sync.registerCallback(self.on_images)
            print_json(dict(type='config', session=self.session, arguments=vars(args),
                            algorithm='depth_final_alignment',
                            camera_to_body=[[0, 1, 0], [-1, 0, 0], [0, 0, 1]],
                            pose_time_basis='ROS reception time', ned_unit='m',
                            bbox_center_unit='pixel', rpy_unit='rad'))

        def warn(self, reason):
            now = time.monotonic()
            if now - self.last_warning.get(reason, -math.inf) >= 3:
                print(f'[bucket-log] {reason}', file=sys.stderr, flush=True)
                self.last_warning[reason] = now

        def now(self):
            return self.get_clock().now().nanoseconds / 1e9

        def mark_stable(self):
            with self.sample_lock:
                latest = self.latest_sample
            if latest is None:
                print('[bucket-log] 尚无有效观测，未标记。', file=sys.stderr, flush=True)
                return
            sample_time, sample = latest
            age = time.monotonic() - sample_time
            if age > max(1.0, 2.0 / args.hz):
                print('[bucket-log] 最新观测已过期，未标记。', file=sys.stderr, flush=True)
                return
            mark = dict(sample, type='stable_mark', stable=True,
                        keypress_wall_time=time.time(), sample_age_s=age)
            print_json(mark)
            print(f'[bucket-log] 已标记稳定样本 #{sample["sequence"]}，'
                  f'桶 NED={sample["bucket_ned"]}', file=sys.stderr, flush=True)

        def on_info(self, msg):
            values = [float(msg.k[i]) for i in (0, 4, 2, 5)]
            if all(math.isfinite(v) for v in values) and min(values[:2]) > 0:
                self.intrinsics = values

        def on_odometry(self, msg):
            q = np.asarray(msg.q, dtype=float)
            if not np.all(np.isfinite(q)) or np.linalg.norm(q) < 1e-6:
                self.attitude = None
                return
            q /= np.linalg.norm(q)
            roll, pitch, _ = Rotation.from_quat([q[1], q[2], q[3], q[0]]).as_euler('xyz')
            self.attitude = (float(roll), float(pitch),
                             int(msg.timestamp_sample or msg.timestamp))

        def on_position(self, msg):
            now = self.now()
            reset = [int(msg.xy_reset_counter), int(msg.z_reset_counter),
                     int(msg.heading_reset_counter)]
            with self.pose_lock:
                if ((self.reset is not None and reset != self.reset)
                        or (self.last_pose_time is not None and now < self.last_pose_time)):
                    self.poses.clear()
                    with self.sample_lock:
                        self.latest_sample = None
                    self.reference_start = now
                    print_json(dict(type='ned_reset', session=self.session,
                                    ros_time=now, reset_counters=reset))
                self.reset = reset
                self.last_pose_time = now
                attitude = self.attitude
                stamp_us = int(msg.timestamp_sample or msg.timestamp)
                if attitude is None or stamp_us <= 0 or attitude[2] <= 0:
                    return
                skew = (stamp_us - attitude[2]) / 1e6
                position = [float(msg.x), float(msg.y), float(msg.z)]
                rpy = [attitude[0], attitude[1], float(msg.heading)]
                if (abs(skew) > 0.10 or not msg.xy_valid or not msg.z_valid
                        or not getattr(msg, 'heading_good_for_control', True)
                        or not all(math.isfinite(v) for v in position + rpy)):
                    return
                velocity = [float(msg.vx), float(msg.vy), float(msg.vz)]
                if not all(math.isfinite(v) for v in velocity):
                    velocity = None
                self.poses.append(dict(ros_time=now, aircraft_ned=position, rpy=rpy,
                                       velocity_ned=velocity, reset_counters=reset,
                                       position_attitude_skew_s=skew))

        def on_images(self, color_msg, depth_msg):
            monotonic_now = time.monotonic()
            if monotonic_now - self.last_inference < 1.0 / args.hz:
                return
            self.last_inference = monotonic_now
            received = self.now()  # 在推理前选定位姿；推理期间仍接收 PX4 数据。
            color_time = color_msg.header.stamp.sec + color_msg.header.stamp.nanosec / 1e9
            depth_time = depth_msg.header.stamp.sec + depth_msg.header.stamp.nanosec / 1e9
            if abs(color_time - depth_time) > 0.04:
                self.warn('RGB/深度不同步，跳过')
                return
            use_source = color_time > 0 and abs(color_time - received) <= 3600
            measurement_time = color_time if use_source else received
            with self.pose_lock:
                if (not self.poses or (self.reference_start is not None
                                      and measurement_time < self.reference_start)):
                    pose = None
                else:
                    pose = min(self.poses, key=lambda s: abs(s['ros_time'] - measurement_time))
            if pose is None or abs(pose['ros_time'] - measurement_time) > 0.20:
                self.warn('等待与图像匹配的有效飞机位置/姿态')
                return
            intrinsics = self.intrinsics
            if intrinsics is None:
                self.warn('等待相机内参')
                return
            try:
                color = self.bridge.imgmsg_to_cv2(color_msg, desired_encoding='bgr8')
                depth = self.bridge.imgmsg_to_cv2(depth_msg, desired_encoding='passthrough')
                if depth.shape != color.shape[:2]:
                    raise ValueError('需要与彩色图对齐、尺寸相同的深度图')
                scale = depth_scale(depth_msg.encoding)
                h, w = depth.shape
                with redirect_stdout(sys.stderr):
                    result = self.model(color, verbose=False)[0]
                candidates = []
                for box in result.boxes:
                    confidence = float(box.conf[0])
                    if int(box.cls[0]) != 0 or not confidence > args.conf:
                        continue
                    x1, y1, x2, y2 = [float(v) for v in box.xyxy[0]]
                    if not all(math.isfinite(v) for v in (x1, y1, x2, y2)):
                        continue
                    center = [(x1+x2)/2, (y1+y2)/2]
                    u, v = int(center[0]), int(center[1])
                    if not (0 <= u < w and 0 <= v < h):
                        continue
                    patch = depth[max(0, v-2):min(h, v+3), max(0, u-2):min(w, u+3)]
                    valid = patch[np.isfinite(patch) & (patch > 0)]
                    z = float(np.median(valid)) * scale if valid.size else 0.0
                    candidates.append(dict(confidence=confidence, depth_m=z,
                                           bbox_center_px=center, sample_pixel=[u, v],
                                           center_distance_sq=(u-w//2)**2+(v-h//2)**2))
                selected = choose_target(candidates)
                if selected is None:
                    self.warn('本帧没有 class 0 且深度有效的桶')
                    return
                fx, fy, cx, cy = intrinsics
                u, v = selected['sample_pixel']
                z = selected['depth_m']
                camera_xyz = [(u-cx)*z/fx, (v-cy)*z/fy, z]
                bucket = camera_to_ned(camera_xyz, pose['aircraft_ned'],
                                       pose['rpy'], self.offset)
                self.sequence += 1
                sample = dict(type='sample', session=self.session, sequence=self.sequence,
                                target_id=args.target_id,
                                aircraft_ned=pose['aircraft_ned'], bucket_ned=bucket,
                                bbox_center_px=selected['bbox_center_px'],
                                sample_pixel=selected['sample_pixel'],
                                depth_m=z, camera_xyz=camera_xyz, confidence=selected['confidence'],
                                intrinsics_fx_fy_cx_cy=intrinsics, rpy=pose['rpy'],
                                velocity_ned=pose['velocity_ned'],
                                reset_counters=pose['reset_counters'],
                                candidate_count=len(candidates), image_size=[w, h],
                                image_time=color_time, receive_time=received,
                                image_time_is_source=use_source,
                                pose_skew_s=pose['ros_time']-measurement_time,
                                position_attitude_skew_s=pose['position_attitude_skew_s'],
                                rgb_depth_skew_s=color_time-depth_time)
                with self.pose_lock:
                    if pose['reset_counters'] != self.reset:
                        return  # 推理期间发生 NED 重置，不记录跨参考系结果。
                    with self.sample_lock:
                        self.latest_sample = (monotonic_now, sample)
                print_json(sample)
            except Exception as exc:
                self.warn(f'采集失败: {exc}')

    global _log_file
    if args.output:
        output = Path(args.output)
        output.parent.mkdir(parents=True, exist_ok=True)
        _log_file = output.open('a', encoding='utf-8')
        print(f'[bucket-log] 日志保存到 {output}', file=sys.stderr, flush=True)
    rclpy.init(args=ros_args)
    node = None
    executor = None
    keyboard = None
    previous_sigterm = signal.getsignal(signal.SIGTERM)

    def terminate(signum, frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, terminate)
    try:
        node = BucketLogger()
        keyboard = KeyboardMarkers(node.mark_stable)
        keyboard.start()
        executor = MultiThreadedExecutor(num_threads=2)
        executor.add_node(node)
        executor.spin()
    except (KeyboardInterrupt, ExternalShutdownException):
        pass
    finally:
        if keyboard is not None:
            keyboard.close()
        if executor is not None:
            executor.shutdown()
        if node is not None:
            node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()
        signal.signal(signal.SIGTERM, previous_sigterm)
        if _log_file is not None:
            _log_file.close()
            _log_file = None


if __name__ == '__main__':
    main()
