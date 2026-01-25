;;; magit-pre-commit.el --- Magit integration for pre-commit -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Damian Barabonkov

;; Author: Damian Barabonkov
;; Keywords: git tools vc
;; Homepage: https://github.com/DamianB-BitFlipper/magit-pre-commit.el
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (magit "3.0.0") (yaml "0.5.0"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This package provides magit integration for pre-commit, the framework
;; for managing and maintaining multi-language pre-commit hooks.
;;
;; Features:
;; - Run pre-commit on staged files or all files
;; - Run specific hooks with completion
;; - Install and update pre-commit hooks
;; - Status section showing running/failed hooks
;;
;; The integration auto-activates when both conditions are met:
;; - The `pre-commit' executable is available in PATH
;; - A `.pre-commit-config.yaml' file exists in the project root

(require 'magit)
(require 'yaml)
(require 'project)
(require 'ansi-color)


;;; Code:

;;; --- Customization ---

(defgroup magit-pre-commit nil
  "Magit integration for pre-commit."
  :group 'magit-extensions
  :prefix "magit-pre-commit-")

(defcustom magit-pre-commit-executable "pre-commit"
  "Path to the pre-commit executable."
  :type 'string)

(defcustom magit-pre-commit-buffer-name "*pre-commit*"
  "Name of the buffer used to display pre-commit output."
  :type 'string)

(defcustom magit-pre-commit-show-buffer-on-failure t
  "Whether to automatically show the pre-commit buffer on failure."
  :type 'boolean)

(defcustom magit-pre-commit-transient-prefix "@"
  "The key to trigger the pre-commit transient from within Magit."
  :type 'string)

;;; --- Internal Variables ---

(defvar magit-pre-commit--process nil
  "The current pre-commit process.")

(defvar magit-pre-commit--last-status nil
  "Status of the last pre-commit run.
Either nil (not run), `running', `success', or `failed'.")

(defvar magit-pre-commit--failed-hooks nil
  "List of hooks that failed in the last run.")

;;; --- Internal Functions ---

(defun magit-pre-commit--project-root ()
  "Return the project root directory, or nil if not in a project."
  (when-let ((project (project-current)))
    (if (fboundp 'project-root)
        (project-root project)
      ;; Fallback for older Emacs
      (car (project-roots project)))))

(defun magit-pre-commit--config-file ()
  "Return the path to .pre-commit-config.yaml, or nil if not found."
  (when-let ((root (magit-pre-commit--project-root)))
    (let ((config (expand-file-name ".pre-commit-config.yaml" root)))
      (when (file-exists-p config)
        config))))

(defun magit-pre-commit-available-p ()
  "Return non-nil if pre-commit is available in current project."
  (and (executable-find magit-pre-commit-executable)
       (magit-pre-commit--config-file)))

(defun magit-pre-commit--parse-hook-ids ()
  "Parse .pre-commit-config.yaml and return a list of hook IDs."
  (when-let ((config-file (magit-pre-commit--config-file)))
    (condition-case err
        (let* ((content (with-temp-buffer
                          (insert-file-contents config-file)
                          (buffer-string)))
               (parsed (yaml-parse-string content
                                          :object-type 'alist
                                          :sequence-type 'list))
               (repos (alist-get 'repos parsed))
               (hook-ids '()))
          (dolist (repo repos)
            (dolist (hook (alist-get 'hooks repo))
              (when-let ((id (alist-get 'id hook)))
                (push (if (symbolp id) (symbol-name id) id) hook-ids))))
          (nreverse hook-ids))
      (error
       (message "Error parsing pre-commit config: %s" (error-message-string err))
       nil))))

(defun magit-pre-commit--get-buffer ()
  "Get or create the pre-commit output buffer."
  (let ((buf (get-buffer-create magit-pre-commit-buffer-name)))
    (with-current-buffer buf
      (unless (eq major-mode 'magit-pre-commit-output-mode)
        (magit-pre-commit-output-mode)))
    buf))

(defun magit-pre-commit--parse-failed-hooks (output)
  "Parse OUTPUT to extract names of failed hooks."
  (let ((failed-hooks '()))
    (with-temp-buffer
      (insert output)
      (goto-char (point-min))
      ;; pre-commit output format: "hook-name....Failed" or "hook-name....Passed"
      (while (re-search-forward "^\\([a-zA-Z0-9_-]+\\)\\.+Failed" nil t)
        (push (match-string 1) failed-hooks)))
    (nreverse failed-hooks)))

(defun magit-pre-commit--sentinel (process event)
  "Process sentinel for pre-commit PROCESS.
EVENT is the process event string."
  (let ((buf (process-buffer process))
        (exit-code (process-exit-status process)))
    (setq magit-pre-commit--process nil)
    (cond
     ((zerop exit-code)
      (setq magit-pre-commit--last-status 'success)
      (setq magit-pre-commit--failed-hooks nil)
      (message "Pre-commit: all hooks passed"))
     (t
      (setq magit-pre-commit--last-status 'failed)
      (when buf
        (with-current-buffer buf
          (setq magit-pre-commit--failed-hooks
                (magit-pre-commit--parse-failed-hooks (buffer-string)))))
      (message "Pre-commit: %d hook(s) failed"
               (length magit-pre-commit--failed-hooks))
      (when (and magit-pre-commit-show-buffer-on-failure buf)
        (display-buffer buf))))
    ;; Refresh magit status to update section
    (when-let ((magit-buf (magit-get-mode-buffer 'magit-status-mode)))
      (with-current-buffer magit-buf
        (magit-refresh)))))

(defun magit-pre-commit--strip-osc-sequences (string)
  "Remove OSC escape sequences (like hyperlinks) from STRING."
  (replace-regexp-in-string "\e\\]8;;[^\e]*\e\\\\" "" string))

(defun magit-pre-commit--filter (process output)
  "Process filter for pre-commit PROCESS.
OUTPUT is the process output string."
  (when-let ((buf (process-buffer process)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((inhibit-read-only t)
              (moving (= (point) (process-mark process))))
          (save-excursion
            (goto-char (process-mark process))
            (insert (ansi-color-apply (magit-pre-commit--strip-osc-sequences output)))
            (set-marker (process-mark process) (point)))
          (when moving
            (goto-char (process-mark process))))))))

(defun magit-pre-commit--run (args &optional hook)
  "Run pre-commit with ARGS.
If HOOK is provided, run only that hook."
  (when magit-pre-commit--process
    (if (yes-or-no-p "Pre-commit is already running.  Kill it? ")
        (progn
          (kill-process magit-pre-commit--process)
          (setq magit-pre-commit--process nil))
      (user-error "Pre-commit is already running")))
  (let* ((default-directory (or (magit-pre-commit--project-root)
                                default-directory))
         (buf (magit-pre-commit--get-buffer))
         (cmd-args (append (list magit-pre-commit-executable "run" "--color=always")
                           (when hook (list hook))
                           args)))
    ;; Prepare buffer
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Running: %s\n\n"
                        (string-join cmd-args " ")))))
    ;; Start process
    (setq magit-pre-commit--last-status 'running)
    (setq magit-pre-commit--failed-hooks nil)
    (setq magit-pre-commit--process
          (make-process
           :name "pre-commit"
           :buffer buf
           :command cmd-args
           :sentinel #'magit-pre-commit--sentinel
           :filter #'magit-pre-commit--filter))
    ;; Refresh magit to show running status
    (when-let ((magit-buf (magit-get-mode-buffer 'magit-status-mode)))
      (with-current-buffer magit-buf
        (magit-refresh)))
    (display-buffer buf)))

;;; --- Output Mode ---

(defvar magit-pre-commit-output-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "q" #'quit-window)
    (define-key map "g" #'magit-pre-commit-run)
    (define-key map "G" #'magit-pre-commit-run-all)
    (define-key map "k" #'magit-pre-commit-kill)
    map)
  "Keymap for `magit-pre-commit-output-mode'.")

(define-derived-mode magit-pre-commit-output-mode special-mode "Pre-commit"
  "Major mode for viewing pre-commit output."
  :group 'magit-pre-commit
  (setq-local truncate-lines t)
  (setq-local buffer-read-only t)
  (setq-local header-line-format
              " g:Run staged  G:Run all  k:Kill  q:Close"))

;;; --- Commands ---

;;;###autoload
(defun magit-pre-commit-run ()
  "Run pre-commit on staged files."
  (interactive)
  (unless (magit-pre-commit-available-p)
    (user-error "Pre-commit not available in this project"))
  (magit-pre-commit--run nil))

;;;###autoload
(defun magit-pre-commit-run-all ()
  "Run pre-commit on all files."
  (interactive)
  (unless (magit-pre-commit-available-p)
    (user-error "Pre-commit not available in this project"))
  (magit-pre-commit--run '("--all-files")))

;;;###autoload
(defun magit-pre-commit-run-hook (hook)
  "Run a specific pre-commit HOOK."
  (interactive
   (list (completing-read "Hook: " (magit-pre-commit--parse-hook-ids) nil t)))
  (unless (magit-pre-commit-available-p)
    (user-error "Pre-commit not available in this project"))
  (magit-pre-commit--run nil hook))

;;;###autoload
(defun magit-pre-commit-install ()
  "Install pre-commit hooks into the git repository."
  (interactive)
  (unless (executable-find magit-pre-commit-executable)
    (user-error "Pre-commit executable not found"))
  (let* ((default-directory (or (magit-pre-commit--project-root)
                                default-directory))
         (buf (magit-pre-commit--get-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Running: pre-commit install\n\n")))
    (make-process
     :name "pre-commit-install"
     :buffer buf
     :command (list magit-pre-commit-executable "install")
     :sentinel (lambda (proc _event)
                 (if (zerop (process-exit-status proc))
                     (message "Pre-commit hooks installed successfully")
                   (message "Failed to install pre-commit hooks"))))
    (display-buffer buf)))

;;;###autoload
(defun magit-pre-commit-autoupdate ()
  "Update pre-commit hooks to their latest versions."
  (interactive)
  (unless (magit-pre-commit-available-p)
    (user-error "Pre-commit not available in this project"))
  (let* ((default-directory (or (magit-pre-commit--project-root)
                                default-directory))
         (buf (magit-pre-commit--get-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Running: pre-commit autoupdate --color=always\n\n")))
    (make-process
     :name "pre-commit-autoupdate"
     :buffer buf
     :command (list magit-pre-commit-executable "autoupdate" "--color=always")
     :filter #'magit-pre-commit--filter
     :sentinel (lambda (proc _event)
                 (if (zerop (process-exit-status proc))
                     (message "Pre-commit hooks updated successfully")
                   (message "Failed to update pre-commit hooks"))))
    (display-buffer buf)))

;;;###autoload
(defun magit-pre-commit-kill ()
  "Kill the running pre-commit process."
  (interactive)
  (if magit-pre-commit--process
      (progn
        (kill-process magit-pre-commit--process)
        (setq magit-pre-commit--process nil)
        (setq magit-pre-commit--last-status nil)
        (message "Pre-commit process killed"))
    (user-error "No pre-commit process running")))

;;; --- Transient ---

;;;###autoload (autoload 'magit-pre-commit "magit-pre-commit" nil t)
(transient-define-prefix magit-pre-commit ()
  "Run pre-commit commands."
  [["Run"
    ("r" "Staged files" magit-pre-commit-run)
    ("a" "All files" magit-pre-commit-run-all)
    ("h" "Specific hook" magit-pre-commit-run-hook)]
   ["Manage"
    ("i" "Install hooks" magit-pre-commit-install)
    ("u" "Update hooks" magit-pre-commit-autoupdate)
    ("k" "Kill process" magit-pre-commit-kill
     :if (lambda () magit-pre-commit--process))]])

;;; --- Magit Status Section ---

(defun magit-pre-commit--status-insert-section ()
  "Insert pre-commit section into magit status buffer."
  (when (and (magit-pre-commit-available-p)
             (memq magit-pre-commit--last-status '(running failed)))
    (magit-insert-section (pre-commit)
      (magit-insert-heading
        (format (propertize "Pre-commit: %s" 'font-lock-face 'magit-section-heading)
                (pcase magit-pre-commit--last-status
                  ('running (propertize "running..." 'font-lock-face 'warning))
                  ('failed (propertize (format "%d hook(s) failed"
                                               (length magit-pre-commit--failed-hooks))
                                       'font-lock-face 'error)))))
      (when (and (eq magit-pre-commit--last-status 'failed)
                 magit-pre-commit--failed-hooks)
        (dolist (hook magit-pre-commit--failed-hooks)
          (insert (propertize (format "  %s\n" hook) 'font-lock-face 'error)))
        (insert "\n")))))

;;; --- Integration ---

(defun magit-pre-commit--setup ()
  "Set up magit-pre-commit integration."
  ;; Add keybinding to magit-mode-map for direct access from status buffer
  (define-key magit-mode-map magit-pre-commit-transient-prefix #'magit-pre-commit)
  ;; Add to magit-dispatch for discoverability
  (transient-insert-suffix 'magit-dispatch "!"
    `(,magit-pre-commit-transient-prefix "Pre-commit" magit-pre-commit :if magit-pre-commit-available-p))
  ;; Add status section hook
  (magit-add-section-hook 'magit-status-sections-hook
                          #'magit-pre-commit--status-insert-section
                          'magit-insert-staged-changes
                          'append))

(defun magit-pre-commit--teardown ()
  "Remove magit-pre-commit integration."
  ;; Remove keybinding from magit-mode-map
  (define-key magit-mode-map magit-pre-commit-transient-prefix nil)
  ;; Remove from magit-dispatch
  (transient-remove-suffix 'magit-dispatch magit-pre-commit-transient-prefix)
  ;; Remove status section hook
  (remove-hook 'magit-status-sections-hook #'magit-pre-commit--status-insert-section))

;; Auto-setup when magit is loaded
(with-eval-after-load 'magit
  (magit-pre-commit--setup))

;;; --- Footer ---

(provide 'magit-pre-commit)

;;; magit-pre-commit.el ends here
