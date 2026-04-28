;nyquist plug-in
;version 4
;type analyze
;categories "http://lv2plug.in/ns/lv2core#UtilityPlugin"
;name "De-Breather Detect..."
;action "Detecting breaths..."
;info "Detects breaths by absence of speech energy in TWO bands\n(upper for consonants, lower for voiced fundamentals)\nand outputs labels marking each detected region.\n\nReview the labels, tweak the settings if needed, and re-run.\nWhen satisfied, use the same settings in De-Breather (Reduce)\nto apply gain reduction, or use Edit > Labelled Audio > Silence\nAudio to silence the labelled regions."
;author "Justin Heath"
;release 1.0.0
;copyright "GPL v2 or later"

;; De-Breather Detect for Audacity
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

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Helpers

(defun mono-mix (snd)
  "Reduce stereo to mono by averaging channels; mono passes through."
  (if (arrayp snd)
      (mult 0.5 (sum (aref snd 0) (aref snd 1)))
      snd))

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

    ;; Stage 3: filter by min duration, build labels
    (let ((labels nil)
          (count 0))
      (dolist (r merged)
        (when (>= (- (cdr r) (car r)) min-frames)
          (incf count)
          (push (list (* (car r) frame-dur)
                      (* (cdr r) frame-dur)
                      (format nil "breath ~a" count))
                labels)))
      (if labels
          (reverse labels)
          "No breaths detected.\n\nTry one or more of:\n  - Raise Max level (less negative)\n  - Lower Min duration\n  - Widen the upper or lower band"))))
