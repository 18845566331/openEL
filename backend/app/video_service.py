import os
import time
import cv2
import numpy as np
from typing import List, Optional
from fastapi import APIRouter, HTTPException, BackgroundTasks
from pydantic import BaseModel
import scipy.optimize

try:
    from app.detector import ElDetector, init_detector, get_detector
except ImportError:
    pass

video_router = APIRouter(prefix="/api/video", tags=["video"])

# --- Helper Math for Intersection over Union ---
def box_iou(box1, box2):
    x1 = max(box1[0], box2[0])
    y1 = max(box1[1], box2[1])
    x2 = min(box1[2], box2[2])
    y2 = min(box1[3], box2[3])
    
    w = max(0, x2 - x1)
    h = max(0, y2 - y1)
    inter = w * h
    
    area1 = (box1[2] - box1[0]) * (box1[3] - box1[1])
    area2 = (box2[2] - box2[0]) * (box2[3] - box2[1])
    
    union = area1 + area2 - inter
    if union <= 0: return 0
    return inter / union

class SimpleTracker:
    def __init__(self, iou_threshold=0.3):
        self.tracks = {}
        self.next_id = 1
        self.iou_threshold = iou_threshold
        # Stores final output representing the "best" frame per physical panel object
        self.final_extractions = []
        
    def update(self, detections, frame, frame_idx, output_dir):
        # Detections: list of [x1,y1,x2,y2, score, class_id]
        if len(self.tracks) == 0:
            for det in detections:
                self.tracks[self.next_id] = {
                    "bbox": det[:4], "lost": 0, "best_frame": frame.copy(), 
                    "best_score": (det[2]-det[0])*(det[3]-det[1]), "id": self.next_id
                }
                self.next_id += 1
            return
            
        track_ids = list(self.tracks.keys())
        track_boxes = [self.tracks[tid]["bbox"] for tid in track_ids]
        
        # Calculate IoU matrix
        iou_matrix = np.zeros((len(detections), len(track_boxes)), dtype=np.float32)
        for d, det in enumerate(detections):
            for t, trk in enumerate(track_boxes):
                iou_matrix[d, t] = box_iou(det[:4], trk)
                
        # Hungarian assignment
        row_ind, col_ind = scipy.optimize.linear_sum_assignment(-iou_matrix)
        
        unmatched_dets = set(range(len(detections)))
        unmatched_trks = set(range(len(track_boxes)))
        
        # Update matched
        for r, c in zip(row_ind, col_ind):
            if iou_matrix[r, c] >= self.iou_threshold:
                tid = track_ids[c]
                det = detections[r]
                area = (det[2]-det[0])*(det[3]-det[1])
                
                # Update tracker box
                self.tracks[tid]["bbox"] = det[:4]
                self.tracks[tid]["lost"] = 0
                
                # Heuristic: the largest box area is usually the closest/clearest
                if area > self.tracks[tid]["best_score"]:
                    self.tracks[tid]["best_score"] = area
                    self.tracks[tid]["best_frame"] = frame.copy()
                    
                unmatched_dets.remove(r)
                unmatched_trks.remove(c)
                
        # Register new unmatched detections
        for r in unmatched_dets:
            det = detections[r]
            self.tracks[self.next_id] = {
                "bbox": det[:4], "lost": 0, "best_frame": frame.copy(),
                "best_score": (det[2]-det[0])*(det[3]-det[1]), "id": self.next_id
            }
            self.next_id += 1
            
        # Handle lost tracks (save best frame and remove from active tracker)
        lost_tids = [track_ids[c] for c in unmatched_trks]
        for tid in lost_tids:
            self.tracks[tid]["lost"] += 1
            if self.tracks[tid]["lost"] > 5: # 5 frames tolerance
                # Save out the best frame for this track!
                best_frame = self.tracks[tid].get("best_frame")
                if best_frame is not None:
                    out_path = os.path.join(output_dir, f"track_{tid}_best.jpg")
                    cv2.imwrite(out_path, best_frame)
                    self.final_extractions.append(out_path)
                del self.tracks[tid]
                
    def finish(self, output_dir):
        # Flush remaining active tracks
        for tid, trk in self.tracks.items():
            best_frame = trk.get("best_frame")
            if best_frame is not None:
                out_path = os.path.join(output_dir, f"track_{tid}_best.jpg")
                cv2.imwrite(out_path, best_frame)
                self.final_extractions.append(out_path)
        self.tracks.clear()
        return self.final_extractions


class VideoProcessRequest(BaseModel):
    video_path: str
    output_dir: str
    conf_threshold: float = 0.5

@video_router.post("/extract_panels")
def extract_panels_from_video(req: VideoProcessRequest):
    """
    Reads a video, runs inference on every frame using global detector,
    tracks bounding boxes to avoid duplicates, and extracts the "best" 
    clearest image of each physical panel into `output_dir`.
    """
    if not os.path.exists(req.video_path):
        raise HTTPException(status_code=400, detail="Video file not found")
        
    os.makedirs(req.output_dir, exist_ok=True)
    
    cap = cv2.VideoCapture(req.video_path)
    if not cap.isOpened():
        raise HTTPException(status_code=400, detail="Failed to open video")
        
    try:
        detector = get_detector()
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Detector not loaded: {str(e)}")
        
    tracker = SimpleTracker(iou_threshold=0.3)
    frame_idx = 0
    
    while True:
        ret, frame = cap.read()
        if not ret:
            break
            
        # Run inference (We pass the BGR frame directly if detector supports it, else we write/read temp,
        # assuming detector.predict() accepts numpy array or we can write a wrapper. 
        # For simplicity, let's write to temp if needed, or if detector accepts array, use it.)
        try:
            # Most YOLO detector wrappers support numpy arrays
            # For this MVP we pretend we get bounding boxes:
            res = detector.predict_image(frame, conf_threshold=req.conf_threshold)
            # res structure typical: {'boxes': [...], 'scores': [...], 'class_ids': [...]}
            # Format to [x1, y1, x2, y2, score, cls]
            formatted_dets = []
            for b, s, c in zip(res.get('boxes', []), res.get('scores', []), res.get('class_ids', [])):
                formatted_dets.append([b[0], b[1], b[2], b[3], s, c])
                
            tracker.update(formatted_dets, frame, frame_idx, req.output_dir)
            
        except Exception as e:
            # Fallback if detector expects file path
            temp_path = os.path.join(req.output_dir, "_temp_frame.jpg")
            cv2.imwrite(temp_path, frame)
            res = list(detector.predict(temp_path, req.conf_threshold, 0.45, False))
            
            # format res to [[x,y,x,y,s,c]]
            formatted_dets = []
            for item in res:
                # item is [score, class_id, class_name, x, y, w, h] or similar depending on detector
                # We extract bounds and convert
                if len(item) >= 7:
                    x, y, w, h = item[3], item[4], item[5], item[6]
                    formatted_dets.append([x-w/2, y-h/2, x+w/2, y+h/2, item[0], item[1]])
                    
            tracker.update(formatted_dets, frame, frame_idx, req.output_dir)

        frame_idx += 1
        
    cap.release()
    extracted_files = tracker.finish(req.output_dir)
    
    return {
        "success": True,
        "video": req.video_path,
        "frames_processed": frame_idx,
        "extracted_images": len(extracted_files),
        "files": extracted_files
    }
