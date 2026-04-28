;nyquist plug-in
;version 4
;type process
;categories "http://lv2plug.in/ns/lv2core#UtilityPlugin"
;name "De-Breather Reduce..."
;action "Reducing breaths..."
;info "Detects breaths by absence of speech energy in TWO bands\n(upper for consonants, lower for voiced fundamentals)\nand reduces their gain by a chosen amount.\n\nLinear fades at each region edge prevent clicks. Set Reduction\nto -100 dB for full silence, or e.g. -20 dB to leave room tone\naudible.\n\nIf result sounds wrong, Undo and re-run with different settings.\nFor a non-destructive preview, use De-Breather Detect first."
;author "Justin Heath"
;release 1.0.0
;copyright "GPL v2 or later"

;; De-Breather Reduce for Audacity
;; Copyright (C) 2026 Justin Heath
;; Licensed under GPL v2 or later
;; https://github.com/MeanTemperature/DeBreather-for-Audacity
;;
;; Built collaboratively with Anthropic's Claude.
;; Bug-spotting assist from Google's Gemini on pwlv-list syntax.

;control upper-low "Upper band low (Hz)" int "" 3000 1500 6000
;control upper-high "Upper band high (Hz)" int "" 8000 4000 16000
;control lower-low "Lower band low (Hz)" int "" 80 40 300
;control lower-high "Lower band high (Hz)" int "" 400 200 1000
;control max-level-db "Max level — both bands (dB RMS)" float "" -45.0 -70.0 -20.0
;control min-duration-ms "Min breath duration (ms)" int "" 500 100 2000
;control gap-ms "Max gap to merge (ms)" int "" 60 0 500
;control window-ms "Analysis window (ms)" int "" 25 10 200
;control reduction-db "Reduction (dB)" float "" -20.0 -100.0 0.0
;control fade-ms "Edge fade (ms)" int "" 20 0 200

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Helpers

(defun mono-mix (snd)
  "Reduce stereo to mono by averaging channels; mono passes through."
  (if (arrayp snd)
      (mult 0.5 (sum (aref snd 0) (aref snd 1)))
      snd))

(defun build-breakpoints (regions srate fade-dur reduction-lin total-dur)
  "Build a flat breakpoint list in pwl-list format:
     (t1 v1 t2 v2 ... tn vn t_final)
   pwl-list has implicit start (0,0) and implicit end value 0.
   We compensate by ramping up from 0 to 1.0 in the first 1ms,
   keeping value 1.0 across the track except dipping to reduction-lin
   inside each region, and ramping back down to 0 in the last 1ms.
   Wrap in abs-env so times are interpreted as absolute seconds."
  (let ((bp (list 0.001 1.0))   ; quick ramp from (0,0) to (0.001, 1.0)
        (last-t 0.001))
    (dolist (r regions)
      (let* ((s-time (/ (float (car r)) (float srate)))
             (e-time (/ (float (cdr r)) (float srate)))
             (region-len (- e-time s-time))
             (f (max 0.0005 (min fade-dur (* region-len 0.4)))))
        ;; Enforce strictly monotonic timestamps
        (when (<= s-time last-t)
          (setf s-time (+ last-t 0.001)))
        (let ((t1 s-time)
              (t2 (+ s-time f))
              (t3 (- e-time f))
              (t4 e-time))
          (when (<= t2 t1) (setf t2 (+ t1 0.0005)))
          (when (<= t3 t2) (setf t3 (+ t2 0.0005)))
          (when (<= t4 t3) (setf t4 (+ t3 0.0005)))
          ;; Append (time, level) pairs
          (setf bp (append bp
                           (list t1 1.0
                                 t2 reduction-lin
                                 t3 reduction-lin
                                 t4 1.0)))
          (setf last-t t4))))
    ;; Hold 1.0 to just before end, then implicit drop to 0 at total-dur
    (let ((penult-t (- total-dur 0.001)))
      (when (> penult-t last-t)
        (setf bp (append bp (list penult-t 1.0)))))
    ;; Final time only (pwl-list ends at implicit value 0)
    (setf bp (append bp (list total-dur)))
    bp))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Main

(let* ((src *track*)
       (mono-src (mono-mix src))
       (srate (snd-srate mono-src))
       (win-samps (max 1 (round (* srate (/ window-ms 1000.0)))))
       (frame-dur (/ win-samps (float srate)))
       (upper (lowpass4 (highpass4 mono-src upper-low) upper-high))
       (lower (lowpass4 (highpass4 mono-src lower-low) lower-high))
       (upper-env (snd-avg (mult upper upper) win-samps win-samps op-average))
       (lower-env (snd-avg (mult lower lower) win-samps win-samps op-average))
       (max-lin-sq (let ((x (db-to-linear max-level-db))) (* x x)))
       (min-frames (max 1 (round (/ min-duration-ms (* 1000.0 frame-dur)))))
       (gap-frames (round (/ gap-ms (* 1000.0 frame-dur))))
       (raw nil)
       (frame 0)
       (in-quiet nil)
       (start-frame 0)
       u-val l-val)

  ;; Stage 1: scan envelopes for "both bands quiet" frames
  (loop
    (setf u-val (snd-fetch upper-env))
    (when (null u-val) (return))
    (setf l-val (snd-fetch lower-env))
    (when (null l-val) (setf l-val 0.0))
    (let ((is-quiet (and (< u-val max-lin-sq) (< l-val max-lin-sq))))
      (cond
        ((and is-quiet (not in-quiet))
          (setf start-frame frame)
          (setf in-quiet t))
        ((and (not is-quiet) in-quiet)
          (push (cons start-frame frame) raw)
          (setf in-quiet nil))))
    (incf frame))
  (when in-quiet
    (push (cons start-frame frame) raw))
  (setf raw (reverse raw))

  ;; Stage 2: merge regions separated by small gaps
  (let ((merged nil))
    (dolist (r raw)
      (cond
        ((and merged (<= (- (car r) (cdr (first merged))) gap-frames))
          (rplacd (first merged) (cdr r)))
        (t (push (cons (car r) (cdr r)) merged))))
    (setf merged (reverse merged))

    ;; Stage 3: filter by min duration, convert to sample indices
    (let ((kept nil))
      (dolist (r merged)
        (when (>= (- (cdr r) (car r)) min-frames)
          (push (cons (* (car r) win-samps) (* (cdr r) win-samps)) kept)))
      (setf kept (reverse kept))

      (cond
        ((null kept)
          ;; No regions found — return source unchanged
          *track*)
        (t
          (let* ((total-dur (get-duration 1))
                 (fade-dur (/ (float fade-ms) 1000.0))
                 (reduction-lin (db-to-linear reduction-db))
                 (bp (build-breakpoints kept srate fade-dur
                                        reduction-lin total-dur)))
            (if (arrayp *track*)
                (vector
                  (mult (aref *track* 0)
                        (abs-env (pwl-list bp)))
                  (mult (aref *track* 1)
                        (abs-env (pwl-list bp))))
                (mult *track*
                      (abs-env (pwl-list bp))))))))))
