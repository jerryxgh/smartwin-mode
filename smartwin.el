;;; smartwin.el --- A minor mode shows shell like buffers. -*- lexical-binding:t -*-

;; Copyright (C) 2015 GuanghuiXu
;; Copyright (C) 2011-2015 Tomohiro Matsuyama

;; Author: GuanghuiXu gh_xu@qq.com
;;         Tomohiro Matsuyama <m2ym.pub@gmail.com>
;; Maintainer: GuanghuiXu gh_xu@qq.com
;; Created: 2015-4-28
;; Keywords: convenience
;; Version: 0.1
;; URL: https://github.com/jerryxgh/smartwin
;; Package-Version: 0.1
;; Package-Requires: ((emacs "24.4"))
;;

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Smartwin is a window for shell buffers, temp buffers and etc.

;; This minor mode let shell like buffers share a window, called smart window,
;; the smart window is always at the bottom of Emacs window.  Besides that, when
;; point move into or out the smart window, it will be enlarged or shrinked
;; automaticly.
;;
;; To use smartwin, place this file to load path and add this to .emacs:
;;
;; (require 'smartwin)
;; (smartwin-mode 1)
;;
;; or run M-x smartwin-mode to toggle it.
;;
;; To switch between buffers of smart window, you can bind keys like:
;;     (define-key smartwin-mode-map (kbd "C-c s") 'smartwin-switch-buffer)
;;
;; Then try run M-x shell or or eshell, if you want to show more buffers in
;; smart window, please customize variable: smartwin-buffers.

;;; Change Log:

;;; TODO:
;; 1. Use new addvice functions to do advice.

;;; BUGS:
;; 1. can not work with guide-key

;;; Code:

(require 'ido)
(require 'esh-mode)

;; for byte-compile warnings
(declare-function evil-window-move-very-top "evil-commands")
(declare-function evil-window-move-very-bottom "evil-commands")
(declare-function evil-window-move-far-left "evil-commands")
(declare-function evil-window-move-far-right "evil-commands")

(defgroup smartwin nil
  "A minor mode for emacs to show shell like buffers"
  :prefix "smartwin-"
  :version "0.1"
  :group 'convenience
  :group 'windows)

(defvar smartwin-scroll-conservatively-backup scroll-conservatively
  "Backup of `scroll-conservatively' to restore it when quit smartwin-mode.")

(defvar smartwin-previous-buffer nil
  "If smart window is hidden, this variable store previous buffer shown in it.")

(defvar smartwin-max-window-height (+ 2 (/ (frame-height) 2))
  "Maximum hight of smart window.
But smart window can be higher if run `delete-other-window' when is is already
  to this height.")

(defcustom smartwin-buffers
  '(;; Emacs
    "*Miniedit Help*"
    completion-list-mode
    compilation-mode
    grep-mode
    occur-mode
    "*scratch*"
    "*evil-registers*"
    "*ielm*"
    "*Inferior Octave*"
    ("^\\*sbt\\*.*" :regexp t)
    "*ensime-db-backtrace-buffer*"
    ;; shell and eshell buffers
    ("^\\*e?shell\\*\\(<.*>\\)?$" :regexp t)
    "*Pp Macroexpand Output*"
    "*Shell Command Output*"
    ;; VC
    "*vc-diff*"
    "*vc-change-log*"
    ;; Undo-Tree
    " *undo-tree*"
    ;; geiser
    " Chicken REPL *"
    ;; Anything
    ("^\\*anything.*\\*$" :regexp t)
    ;; SLIME
    "*slime-apropos*"
    "*slime-macroexpansion*"
    "*slime-description*"
    "*slime-compilation*"
    "*slime-xref*"
    sldb-mode
    slime-repl-mode
    slime-connection-list-mode)
  "Configuration of buffers to be shown in smart window."
  :type '(repeat
          (cons :tag "Config"
                (choice :tag "Pattern"
                        (string :tag "Buffer Name")
                        (symbol :tag "Major Mode"))
                (plist :tag "Keywords"
                       :value (:regexp nil)
                       :options
                       ((:regexp (boolean :tag "On/Off"))))))
  :get (lambda (symbol)
         (mapcar (lambda (element)
                   (if (consp element)
                       element
                     (list element)))
                 (default-value symbol)))
  :group 'smartwin)

(defun smartwin--match-buffer (buffer-or-name)
  "Judge whether to use smartwin to show BUFFER-OR-NAME."
  (let ((buffer (get-buffer buffer-or-name)))
    (if buffer
        (let ((name (buffer-name buffer))
              (mode (buffer-local-value 'major-mode buffer)))
          (catch 'break
            (dolist (config smartwin-buffers)
              (let ((pattern (if (consp config) (car config) config))
                    (keywords (if (consp config) (cdr config) nil)))
                (if (cond ((eq pattern t) (not (buffer-file-name buffer)))
                          ((and (stringp pattern) (plist-get keywords :regexp))
                           (string-match pattern name))
                          ((stringp pattern)
                           (string= pattern name))
                          ((symbolp pattern)
                           (eq pattern mode))
                          ((functionp pattern)
                           (funcall pattern buffer))
                          (t (error "Invalid pattern: %s" pattern)))
                    (throw 'break config)))))))))

(defun smartwin--kill-buffer-when-shell-exit (&optional buffer)
  "Kill the buffer on exit of interactive shell.
if BUFFER is nil, use `current-buffer'."
  (let* ((buf (or buffer (current-buffer)))
         (process (get-buffer-process buf)))
    (if process
        (set-process-sentinel
         process
         #'(lambda (process state)
             (when (or (string-match "exited abnormally with code." state)
                       (string-match "\\(finished\\|exited\\)" state))
               (quit-window t (get-buffer-window (process-buffer process)))))))))

(defun smartwin--min-window-height (window)
  "Minimal hight of WINDOW."
  (- (window-height window)
     (window-min-delta window nil nil nil nil nil)))

(defun smartwin--shrink-window (window)
  "Try to shirnk smart WINDOW."
  (if (> (window-height window) (smartwin--min-window-height window))
      (minimize-window window)))

(defun smartwin--enlarge-window (window)
  "Try to enlarge smart WINDOW."
  (let ((height-before (window-height window))
        (window-start (window-start))
        (window-end (window-end)))
    (fit-window-to-buffer window
                          smartwin-max-window-height
                          (smartwin--min-window-height window))
    ;; set smart window start
    (if (> (window-height window) height-before)
        (let ((forward-line-num (- height-before (window-height window)))
              left-to-forward)
          (set-window-start
           window
           (let (return done)
             (while (not done)
               (save-excursion
                 (goto-char window-start)
                 (setq left-to-forward (forward-line forward-line-num))
                 (setq return (window-point window))
                 (if (or (eq window-end (window-end))
                         left-to-forward
                         (>= forward-line-num 0))
                     (setq done t)
                   (setq forward-line-num (+ forward-line-num 1)))
                 ))
             return)
           t)))))

(defun smartwin--get-bottom-window ()
  "Try to get bottom window.
A bottom is such a window: it not the only normal(non minibuffer) window and
it's width is equal to frame width."
  (let ((root-tree (car (window-tree (selected-frame)))))
    (if (and (listp root-tree) (car root-tree))
        (let ((bottom-window (car (last root-tree))))
          (if (windowp bottom-window)
              bottom-window
            nil)))))

(defun smartwin--smart-window-p (window)
  "To judge whether WINDOW is smart window or not."
  (and window
       (windowp window)
       (eq window (smartwin--get-bottom-window))
       (smartwin--match-buffer (window-buffer window))))

(defun smartwin--get-smart-window ()
  "Find smart window among all live windows.
If found, return the window, else return nil."
  (let ((bottom-window (window-last-child (frame-root-window))))
    (if (smartwin--smart-window-p bottom-window)
        bottom-window
      nil)))

(defun smartwin--get-befitting-window ()
  "Try to get an existing befitting bottom window as smart window."
  (let ((bottom-window (smartwin--get-bottom-window)))
    (if (and (windowp bottom-window)
             (<= (window-height bottom-window) (smartwin--min-window-height
                                                bottom-window)))
              bottom-window
            nil)))

(defun smartwin--create-befitting-window ()
  "Try to split root window to create smart window."
  (let* ((root-win (frame-root-window))
         (root-height (window-height root-win)))
    (if (frame-parameter nil 'unsplittable)
        nil
      (with-demoted-errors "Warning: %S"
        (split-window root-win (- root-height window-min-height) 'below)))))

(defun smartwin--get-or-create-smart-window ()
  "Get or create the smart window.
If succeed, a smart window is returned, else return nil."
  (let ((window (smartwin--get-smart-window)))
    (if window
        window
      (setq window (or (smartwin--get-befitting-window)
                       (smartwin--create-befitting-window)))
      (when window
        (set-window-dedicated-p window nil)
        (set-window-buffer window (or (get-buffer "*scratch*")
                                      (smartwin-create-scratch-buffer)))
        (set-window-dedicated-p window t)
        (set-window-prev-buffers window nil))
      window)))

(defun smartwin--get-largest-window (&optional all-frames dedicated not-selected)
  "Like `get-largest-window', but smart window is excluded.
About ALL-FRAMES, DEDICATED and NOT-SELECTED, please see `get-largest-window'"
  (let ((best-size 0)
        best-window size)
    (dolist (window (window-list-1 nil 'nomini all-frames))
      (when (and (not (smartwin--smart-window-p window))
                 (or dedicated (not (window-dedicated-p window)))
                 (or (not not-selected) (not (eq window (selected-window)))))
        (setq size (* (window-total-size window)
                      (window-total-size window t)))
        (when (> size best-size)
          (setq best-size size)
          (setq best-window window))))
    best-window))

(defun smartwin--get-lru-window (&optional all-frames dedicated not-selected)
  "Like `get-lru-window', but smart window is excluded.
About ALL-FRAMES, DEDICATED and NOT-SELECTED, please see `get-lru-window'"
  (let (best-window best-time second-best-window second-best-time time)
    (dolist (window (window-list-1 nil 'nomini all-frames))
      (when (and (not (smartwin--smart-window-p window))
                 (or dedicated (not (window-dedicated-p window)))
                 (or (not not-selected) (not (eq window (selected-window)))))
        (setq time (window-use-time window))
        (if (or (eq window (selected-window))
                (not (window-full-width-p window)))
            (when (or (not second-best-time) (< time second-best-time))
              (setq second-best-time time)
              (setq second-best-window window))
          (when (or (not best-time) (< time best-time))
            (setq best-time time)
            (setq best-window window)))))
    (or best-window second-best-window)))

(defun smartwin--get-mru-window (&optional all-frames dedicated not-selected)
  "Like `get-mru-window', but smart window is excluded.
About ALL-FRAMES, DEDICATED and NOT-SELECTED, please see `get-mru-window'"
  (let (best-window best-time time)
    (dolist (window (window-list-1 nil 'nomini all-frames))
      (setq time (window-use-time window))
      (when (and (not (smartwin--smart-window-p window))
                 (or dedicated (not (window-dedicated-p window)))
                 (or (not not-selected) (not (eq window (selected-window))))
                 (or (not best-time) (> time best-time)))
        (setq best-time time)
        (setq best-window window)))
    best-window))

;;; work with others
;; ediff
(add-hook 'ediff-before-setup-hook 'smartwin-hide)

;;; advices

(defadvice evil-window-move-far-left
    (around smartwin-around-evil-window-move-far-left)
  "When `evil-window-move-far-left', ignore smart window."
  (if (not (smartwin--smart-window-p (selected-window)))
      (if (smartwin--get-smart-window)
          (progn
            (smartwin-hide)
            ad-do-it
            (smartwin-show))
        ad-do-it)
    (message "Attempt to move smart window")))

(defadvice evil-window-move-far-right
    (around smartwin-around-evil-window-move-far-right)
  "When `evil-window-move-far-right', ignore smart window."
  (if (not (smartwin--smart-window-p (selected-window)))
      (if (smartwin--get-smart-window)
          (progn
            (smartwin-hide)
            ad-do-it
            (smartwin-show))
        ad-do-it)
    (message "Attempt to move smart window")))

(defadvice evil-window-move-very-top
    (around smartwin-around-evil-window-move-very-top)
  "When `evil-window-move-very-top', ignore smart window."
  (if (not (smartwin--smart-window-p (selected-window)))
      (if (smartwin--get-smart-window)
          (progn
            (smartwin-hide)
            ad-do-it
            (smartwin-show))
        ad-do-it)
    (message "Attempt to move smart window")))

(defadvice evil-window-move-very-bottom
    (around smartwin-around-evil-window-move-very-bottom)
  "When `evil-window-move-very-bottom', ignore smart window."
  (if (not (smartwin--smart-window-p (selected-window)))
      (if (smartwin--get-smart-window)
          (progn
            (smartwin-hide)
            ad-do-it
            (smartwin-show))
        ad-do-it)
    (message "Attempt to move smart window")))

(defadvice balance-windows (around smartwin-around-balance-windows)
  "When do `balance-windows', ignore smart window."
  (let ((smart-window (smartwin--get-smart-window))
        (window-or-frame (ad-get-arg 0)))
    (if (and smart-window
             (or (not (windowp window-or-frame))
                 ;; the only two ancestor windows of smart window
                 (eq window-or-frame (frame-root-window))
                 (eq window-or-frame (window-parent smart-window))))
        (ad-set-arg 0 (window-prev-sibling smart-window)))
    ad-do-it))

(defadvice gdb (before smartwin-before-gdb)
  "When run `gdb', hide smart window."
  (smartwin-hide))

;;; Minor Mode

(defun smartwin--display-buffer-condition (buffer-or-name _action)
  "Part of pair in `display-buffer-alist'.
BUFFER-OR-NAME is a buffer name to match, _ACTION is not used."
  (smartwin--match-buffer buffer-or-name))

(defun smartwin--display-buffer-action (buffer-or-name _alist)
  "Part of pair in `display-buffer-alist'.
BUFFER-OR-NAME is a buffer to display, _ALIST is not used."
  (let ((buffer (window-normalize-buffer-to-switch-to buffer-or-name))
        (smart-win (smartwin--get-or-create-smart-window)))
    (with-selected-window smart-win
      (set-window-dedicated-p smart-win nil)
      (set-window-buffer smart-win buffer)
      (set-window-dedicated-p smart-win t))
    smart-win))

(defun smartwin-hide ()
  "Hide smart window, store its buffer as previous buffer."
  (interactive)
  (let ((window (smartwin--get-smart-window)))
    (when window
      (setq smartwin-previous-buffer (window-buffer window))
      (delete-window window))))

(defun smartwin--make-smart-buffer-list ()
  "Return smart buffer list that not shown in smartwin."
  (let ((visible-buffers (ido-get-buffers-in-frames 'current)))
    (delq nil
          (mapcar
           (lambda (x)
             (let ((name (buffer-name x)))
               (if (and (smartwin--match-buffer x)
                        (not (member name visible-buffers)))
                   name)))
           (buffer-list)))))

(defun smartwin--make-normal-buffer-list ()
  "Return list of normal buffers that not shown."
  (let ((visible-buffers (ido-get-buffers-in-frames 'current)))
    (delq nil
          (mapcar
           (lambda (x)
             (let ((name (buffer-name x)))
               (if (and (not (smartwin--match-buffer x))
                        (not (member name visible-buffers))
                        (not (string-match "^ ?\\*" name)))
                   name)))
           (buffer-list)))))

(defun smartwin-switch-buffer ()
  "Pop buffer that can be showed in smartwin.
This function get input by ido."
  (interactive)
  (let* ((smartwin-buffers (smartwin--make-smart-buffer-list))
         (chosen (and smartwin-buffers
                      (ido-completing-read "Smartwin:" smartwin-buffers)))
         (buffer (and chosen
                      (not (string= chosen ""))
                      (get-buffer chosen))))
    (if (not buffer)
        (if (not smartwin-buffers)
            (progn
              (message
               "Then only one smartwin buffer has been shown, no other buffers")
              (select-window (smartwin--get-or-create-smart-window)))
          (message (format "Buffer %s not exist" chosen)))
      (let ((window (smartwin--get-or-create-smart-window)))
        (set-window-dedicated-p window nil)
        (set-window-buffer window buffer)
        (set-window-dedicated-p window t)
        (select-window window)))))

(defun smartwin-create-scratch-buffer ()
  "Create a scratch buffer with the scratch message."
  (interactive)
  (unless (get-buffer "*scratch*")
    (with-current-buffer (get-buffer-create "*scratch*")
      (progn
        (insert initial-scratch-message)
        (goto-char (point-max))
        (lisp-interaction-mode)
        (current-buffer)))))

(defun smartwin--get-C-l-command ()
  "Get the command <tab> should be bound.
According to `major-mode' that yasnippet is not enabled and the
`global-map'."
  (let ((major-mode-map
         (symbol-value (intern-soft (concat (symbol-name major-mode) "-map")))))
    (or (and major-mode-map
             (lookup-key major-mode-map (kbd "C-l")))
        (lookup-key global-map (kbd "C-l")))))

(defun smartwin-clear-shell ()
  "Clear `eshell' or submode of `comint-mode' buffer."
  (interactive)
  (cond ((eq major-mode 'eshell-mode)
         (let ((eshell-buffer-maximum-lines 0))
           (eshell-truncate-buffer)
           (fit-window-to-buffer (selected-window)
                                 smartwin-max-window-height
                                 (smartwin--min-window-height (selected-window)))))
        ((derived-mode-p 'comint-mode)
         (let ((comint-buffer-maximum-size 0))
           (comint-truncate-buffer)
           (fit-window-to-buffer (selected-window)
                                 smartwin-max-window-height
                                 (smartwin--min-window-height (selected-window)))))
        (t (command-execute (smartwin--get-C-l-command)))))

(defun smartwin-clear-scratch-buffer (&optional buffer-or-name)
  "Clear the scratch buffer and keep the scratch message.
If BUFFER-OR-NAME is not nil, treat is as scratch buffer."
  (interactive)
  (let ((buffer (if (not buffer-or-name)
                    (get-buffer "*scratch*")
                  (get-buffer buffer-or-name))))
    (if initial-scratch-message
        (with-current-buffer buffer
          (delete-region (point-min) (point-max))
          (insert initial-scratch-message)
          (set-buffer-modified-p nil)
          (goto-char (point-max))))))

(defun smartwin--auto-enlarge-shrink-hook ()
  "Automatically enlarge or shrink smart window when do `select-window'."
  (let ((smart-win (smartwin--get-smart-window)))
    (when smart-win
      (set-window-dedicated-p smart-win t)
      (if (eq (selected-window) smart-win)
          (smartwin--enlarge-window smart-win)
        (smartwin--shrink-window smart-win)))))

;;;###autoload
(define-minor-mode smartwin-mode
  "Toggle smartwin minor mode.
Smartwin is a window for showing shell like buffers, temp buffers and etc."
  :lighter " sw"
  :init-value nil
  :global t
  :group 'smartwin
  ;; The minor mode bindings.
  :keymap (make-sparse-keymap)
  (let ((pair '(smartwin--display-buffer-condition
                smartwin--display-buffer-action)))
    (if smartwin-mode
        (progn
          ;; backup scroll-conservatively to restore it when quit smartwin-mode
          (setq smartwin-scroll-conservatively-backup scroll-conservatively)
          (setq scroll-conservatively (- most-positive-fixnum 1))
          (push pair display-buffer-alist)

          (ad-activate #'evil-window-move-very-top)
          (ad-activate #'evil-window-move-far-left)
          (ad-activate #'evil-window-move-far-right)
          (ad-activate #'evil-window-move-very-bottom)
          (ad-activate #'balance-windows)
          (ad-activate #'gdb)

          (add-hook 'buffer-list-update-hook #'smartwin--auto-enlarge-shrink-hook)
          (add-hook 'comint-mode-hook #'smartwin--kill-buffer-when-shell-exit)
          (add-hook 'kill-emacs-hook #'smartwin-hide)
          (smartwin-create-scratch-buffer)

          (if (buffer-live-p smartwin-previous-buffer)
              (smartwin-show)))

      ;; restore scroll-conservatively when it equal to smartwin's setting
      (if (eq scroll-conservatively (- most-positive-fixnum 1))
          (setq scroll-conservatively smartwin-scroll-conservatively-backup))

      (remove-hook 'comint-mode-hook #'smartwin--kill-buffer-when-shell-exit)
      (remove-hook 'kill-emacs-hook #'smartwin-hide)
      (remove-hook 'buffer-list-update-hook #'smartwin--auto-enlarge-shrink-hook)

      (setq display-buffer-alist (delete pair display-buffer-alist))

      (ad-deactivate #'evil-window-move-very-top)
      (ad-deactivate #'evil-window-move-far-left)
      (ad-deactivate #'evil-window-move-far-right)
      (ad-deactivate #'evil-window-move-very-bottom)
      (ad-deactivate #'balance-windows)
      (ad-deactivate #'gdb)

      (smartwin-hide))))

(defun smartwin-show ()
  "Show smart window."
  (interactive)
  (if smartwin-mode
      (let ((window (smartwin--get-smart-window)))
        (when (not window)
          (setq window (smartwin--get-or-create-smart-window))
          (if (and smartwin-previous-buffer
                   (buffer-live-p smartwin-previous-buffer))
              (when (not (eq smartwin-previous-buffer (window-buffer window)))
                (set-window-dedicated-p window nil)
                (set-window-buffer window smartwin-previous-buffer)
                (set-window-dedicated-p window t))))
        (if (called-interactively-p 'interactive)
            (select-window window)))
    (message "Smartwin-mode is not enabled, do nothing")))


(provide 'smartwin)

;;; smartwin.el ends here
