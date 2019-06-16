;;; helm-pinboard.el --- helm extensions for pinboard bookmarks

;; Filename: helm-pinboard.el
;; Description: helm-pinboard fetch all your bookmarks and then visit them via helm
;; Maintainer: Ben Hyde
;; Copyright (C) 2019 Ben Hyde <bhyde@pobox.com>, all rights reserved
;; Version: 1.0
;; Package-Requires (helm-mode xml)
;; Last-Updated: 2013-10-21 01:28:00
;; URL: https://github.com/bhyde/helm-pinboard
;; Keywords: pinboard bookmarks helm
;; Compatibility: Gnus Emacs 24.3
 
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 3, or
;; (at your option) any later version.
;; 
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;; 
;; You should have received a copy of the GNU General Public License
;; along with this program; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 51 Franklin Street, Fifth
;; Floor, Boston, MA 02110-1301, USA.

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; 
;;; Commentary:
;;  ==========
;;
;; This package helm-pinboard, provides one command M-x helm-pinboard.
;; That let's you browse you pinboard resident bookmarks via helm.
;;
;; Pinboard.in is a bookmarking site, similar to the now retired
;; del.icio.us that Yahoo bought for 30M back in the day.  Except
;; that it is less social, more private, etc. etc.
;;
;; This code use curl and wget; so you'll want those installed.
;; It depends on the `helm' and 'xml' as well.
;; 
;; You might install this by placing this form in your init file.
;; 
;;   (use-package helm-pinboard
;;     ;; :ensure ; Enable if this is your preference.
;;     :commands helm-pinboard
;;     :quelpa (helm-pinboard :fetcher github :repo "bhyde/helm-pinboard")
;;     :after helm-mode xml
;;     :custom (;; Typically you needn't customize anything.
;;              ;; (customize-set-variable 'helm-c-pinboard-cache-file "~/.pinboard.cache")
;;              ;; (customize-set-variable 'helm-wget (executable-find "wget"))
;;              ))
;;
;; Authentication with pinboard:
;;
;;   Define`helm-pinboard-user' and `helm-pinboard-password'
;;
;; or better:
;;
;; Add a line like this in your .authinfo file:
;;
;; machine api.pinboard.in:443 port https login xxxxx password xxxxx
;;
;; and add to you init file (.emacs):
;; (require 'auth-source)
;;
;; (if (file-exists-p "~/.authinfo.gpg")
;;     (setq auth-sources '((:source "~/.authinfo.gpg" :host t :protocol t)))
;;     (setq auth-sources '((:source "~/.authinfo" :host t :protocol t))))
;;
;; Warning:
;;
;; DON'T CALL `helm-pinboard-authentify', this will set your login and password
;; globally.
;;
;; Use:
;; ===
;;
;; M-x helm-pinboard
;; That should create a "~/.pinboard-cache" file.
;; (you can set that to another value with `helm-c-pinboard-cache-file')
;; You can also add `helm-c-source-pinboard-tv' to the `helm-sources'.
;; 
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
 
;;; Code:

(require 'xml)

;; User variables
(defvar helm-c-pinboard-api-url
  "https://api.pinboard.in/v1/posts/all?"
  "Url used to retrieve all bookmarks")
(defvar helm-c-pinboard-api-url-delete
  "https://api.pinboard.in/v1/posts/delete?&url=%s"
  "Url used to delete bookmarks from pinboard")
(defvar helm-c-pinboard-api-url-add
  "https://api.pinboard.in/v1/posts/add?&url=%s&description=%s&tags=%s"
  "Url used to add bookmarks to pinboard")

(defcustom helm-c-pinboard-cache-file "~/.pinboard.cache"
  "The location of the cache file for `helm-pinboard'."
  :group 'helm
  :type 'file)
(defcustom helm-wget (executable-find "wget")
  "The location of the wget executable file for `helm-pinboard'."
  :group 'helm
  :type 'file)

(defvar helm-pinboard-user nil
  "Your Pinboard login")
(defvar helm-pinboard-password nil
  "Your Pinboard password")

;; Faces
(defface helm-pinboard-tag-face '((t (:foreground "VioletRed4" :weight bold)))
  "Face for w3m bookmarks" :group 'helm)

(defface helm-pinboard-bookmarks-face '((t (:foreground "blue" :underline t)))
  "Face for w3m bookmarks" :group 'helm)

;; Internal variables (don't modify)
(defvar helm-c-pinboard-cache nil)
(defvar helm-pinboard-last-candidate-to-deletion nil)
(defvar helm-pinboard-last-pattern nil)
                                     
(defvar helm-c-source-pinboard-tv
  '((name . "pinboard.in")
    (init . (lambda ()
              (unless helm-c-pinboard-cache
                (setq helm-c-pinboard-cache
                      (helm-set-up-pinboard-bookmarks-alist)))))
    (candidates . (lambda () (mapcar #'car helm-c-pinboard-cache)))
    (candidate-transformer helm-c-highlight-pinboard-bookmarks)
    (action . (("Browse Url default" . (lambda (elm)
                                 (helm-c-pinboard-browse-bookmark elm)
                                 (setq helm-pinboard-last-pattern helm-pattern)))
               ("Browse Url Firefox" . (lambda (candidate)
                                         (helm-c-pinboard-browse-bookmark candidate 'firefox)))
               ("Browse Url Chromium" . (lambda (candidate)
                                         (helm-c-pinboard-browse-bookmark candidate 'chromium)))
               ("Browse Url w3m" . (lambda (candidate)
                                         (helm-c-pinboard-browse-bookmark candidate 'w3m)
                                         (setq helm-pinboard-last-pattern helm-pattern)))
               ("Browse Url eww" . (lambda (candidate)
                                         (helm-c-pinboard-browse-bookmark candidate 'eww)
                                         (setq helm-pinboard-last-pattern helm-pattern)))
               ("Delete bookmark" . (lambda (elm)
                                      (helm-c-pinboard-delete-bookmark elm)))
               ("Copy Url" . (lambda (elm)
                               (kill-new (helm-c-pinboard-bookmarks-get-value elm))))
               ("Update" . (lambda (elm)
                             (message "Wait Loading bookmarks from Pinboard...")
                             (helm-wget-retrieve-pinboard)))))))


;; (helm 'helm-c-source-pinboard-tv)

(defvar helm-source-is-pinboard nil)
(defadvice helm-select-action (before remember-helm-pattern () activate)
  "Remember helm-pattern when opening helm-action-buffer"
  (when helm-source-is-pinboard
    (setq helm-pinboard-last-pattern helm-pattern)))

(defun helm-pinboard-remove-flag ()
  (setq helm-source-is-pinboard nil))

(add-hook 'helm-cleanup-hook 'helm-pinboard-remove-flag)

(defun helm-pinboard-authentify ()
  "Authentify user from .authinfo file.
You have to setup correctly `auth-sources' to make this function
finding the path of your .authinfo file that is normally ~/.authinfo."
  (let ((helm-pinboard-auth
         (auth-source-user-or-password  '("login" "password")
                                        "api.pinboard.in:443"
                                        "https")))
    (when helm-pinboard-auth
      (setq helm-pinboard-user (car helm-pinboard-auth)
            helm-pinboard-password (cadr helm-pinboard-auth))
      nil)))


;;;###autoload
(defun helm-wget-retrieve-pinboard (&optional sentinel)
  "Get the pinboard bookmarks asynchronously with external program wget."
  (interactive)
  (let ((fmd-command "%s -q --no-check-certificate -O %s --user %s --password %s %s"))
    (unless (and helm-pinboard-user helm-pinboard-password)
      (helm-pinboard-authentify))
    (message "Syncing with Pinboard in Progress...")
    (start-process-shell-command
     "wget-retrieve-pinboard" nil
     (format fmd-command
             helm-wget
             helm-c-pinboard-cache-file
             helm-pinboard-user
             helm-pinboard-password
             helm-c-pinboard-api-url))
    (set-process-sentinel
     (get-process "wget-retrieve-pinboard")
     (if sentinel
         sentinel
         #'(lambda (process event)
             (if (string= event "finished\n")
                 (message "Syncing with Pinboard...Done.")
                 (message "Failed to synchronize with Pinboard."))
             (setq helm-c-pinboard-cache nil))))))


(defun helm-c-pinboard-delete-bookmark (candidate &optional url-value-fn sentinel)
  "Delete pinboard bookmark on the pinboard side"
  (let* ((url     (if url-value-fn
                      (funcall url-value-fn candidate)
                      (helm-c-pinboard-bookmarks-get-value candidate)))
         (url-api (format helm-c-pinboard-api-url-delete
                          url))
         helm-pinboard-user
         helm-pinboard-password
         auth)
    (unless (and helm-pinboard-user helm-pinboard-password)
      (helm-pinboard-authentify))
    (setq auth (concat helm-pinboard-user ":" helm-pinboard-password))
    (message "Wait sending request to pinboard...")
    (setq helm-pinboard-last-candidate-to-deletion candidate)
    (apply #'start-process "curl-pinboard-delete" "*pinboard-delete*" "curl"
                   (list "-u"
                         auth
                         url-api))
    (set-process-sentinel (get-process "curl-pinboard-delete")
                          (or sentinel 'helm-pinboard-delete-sentinel))))


(defun helm-pinboard-delete-sentinel (process event)
  "Sentinel func for `helm-c-pinboard-delete-bookmark'"
  (message "%s process is %s" process event)
  (sit-for 1)
  (with-current-buffer "*pinboard-delete*"
    (goto-char (point-min))
    (if (re-search-forward "<result code=\"done\" />" nil t)
        (progn
          (helm-c-pinboard-delete-bookmark-local
           helm-pinboard-last-candidate-to-deletion)
          (setq helm-c-pinboard-cache nil)
          (message "Ok %s have been deleted with success"
                   (substring-no-properties
                    helm-pinboard-last-candidate-to-deletion)))
        (message "Fail to delete %s"
                 (substring-no-properties
                  helm-pinboard-last-candidate-to-deletion)))
    (setq helm-pinboard-last-candidate-to-deletion nil)))


(defun helm-c-pinboard-delete-bookmark-local (candidate)
  "Delete pinboard bookmark on the local side"
  (let ((cand (when (string-match "\\[.*\\]" candidate)
                (substring candidate (1+ (match-end 0))))))
    (with-current-buffer (find-file-noselect helm-c-pinboard-cache-file)
      (goto-char (point-min))
      (when (re-search-forward cand (point-max) t)
        (beginning-of-line)
        (delete-region (point) (point-at-eol))
        (delete-blank-lines))
      (save-buffer)
      (kill-buffer (current-buffer)))))

(defun helm-set-up-pinboard-bookmarks-alist ()
  "Setup an alist of all pinboard bookmarks from xml file"
  (let ((gen-alist ())
        (tag-list ())
        (tag-len 0))
    (unless (file-exists-p helm-c-pinboard-cache-file)
      (message "Wait Loading bookmarks from Pinboard...")
      (helm-wget-retrieve-pinboard))
    (setq tag-list (helm-pinboard-get-all-tags-from-cache))
    (loop for i in tag-list
          for len = (length i) 
          when (> len tag-len) do (setq tag-len len))
    (with-temp-buffer
      (insert-file-contents helm-c-pinboard-cache-file)
      (setq gen-alist (xml-get-children
                       (car (xml-parse-region (point-min)
                                              (point-max)))
                       'post)))
    (loop for i in gen-alist
          for tag = (xml-get-attribute i 'tag)
          for desc = (xml-get-attribute i 'description)
          for url = (xml-get-attribute i 'href)
          for interval = (- tag-len (length tag))
          collect (cons (concat "[" tag "] " desc) url))))

;;;###autoload
(defun w3m-add-pinboard-bookmark (description tag)
  "Add a bookmark to pinboard from w3m"
  (interactive (list (read-from-minibuffer "Description: "
                                           nil nil nil nil
                                           w3m-current-title)
                     (completing-read "Tag: "
                                      (helm-pinboard-get-all-tags-from-cache))))
  (setq description
        (replace-regexp-in-string " " "+" description))
  (let* ((url     w3m-current-url)
         (url-api (format helm-c-pinboard-api-url-add url description tag))
         helm-pinboard-user
         helm-pinboard-password
         auth)
    (unless (and helm-pinboard-user helm-pinboard-password)
      (helm-pinboard-authentify))
    (setq auth (concat helm-pinboard-user ":" helm-pinboard-password))
    (with-temp-buffer
      (apply #'call-process "curl" nil t nil
             `("-u"
               ,auth
               ,url-api))
      (buffer-string)
      (goto-char (point-min))
      (if (re-search-forward "<result code=\"done\" />" nil t)
          (unwind-protect
               (progn
                 (message "%s added to pinboard" description)
                 (when current-prefix-arg
                   (w3m-bookmark-write-file url
                                            (replace-regexp-in-string "\+"
                                                                      " "
                                                                      description)
                                            tag)
                   (message "%s added to pinboard and to w3m-bookmarks" description)))
            (helm-wget-retrieve-pinboard))
          (message "Fail to add bookmark to pinboard")
          (when current-prefix-arg
            (if (y-or-n-p "Add anyway to w3m-bookmarks?")
                (progn
                  (w3m-bookmark-write-file url
                                           (replace-regexp-in-string "\+" " "
                                                                     description)
                                           tag)
                  (message "%s added to w3m-bookmarks" description))))))))

(defun helm-pinboard-get-all-tags-from-cache ()
  "Get the list of all your tags from Pinboard
That is used for completion on tags when adding bookmarks
to Pinboard"
  (with-current-buffer (find-file-noselect helm-c-pinboard-cache-file)
    (goto-char (point-min))
    (let* ((all (car (xml-parse-region (point-min) (point-max))))
           (tag (xml-get-children all 'post))
           tag-list)
      (dolist (i tag)
        (let ((tg (xml-get-attribute i 'tag)))
          (unless (member tg tag-list) (push tg tag-list))))
      (kill-buffer)
      tag-list)))

(defun helm-c-pinboard-bookmarks-get-value (elm)
  "Get the value of key elm from alist"
  (replace-regexp-in-string
   "\"" "" (cdr (assoc elm helm-c-pinboard-cache))))

(defun helm-c-pinboard-browse-bookmark (x &optional browser new-tab)
  "Action function for helm-pinboard"
  (let* ((fn (case browser
               (firefox 'browse-url-firefox)
               (chromium 'browse-url-chromium)
               (w3m 'w3m-browse-url)
               (eww 'browse-url-eww)
               (t 'browse-url)))
         (arg (and (eq fn 'w3m-browse-url) new-tab)))
    (dolist (elm (helm-marked-candidates))
      (funcall fn (helm-c-pinboard-bookmarks-get-value elm) arg))))

(defun helm-c-highlight-pinboard-bookmarks (books)
  "Highlight all Pinboard bookmarks"
  (let (tag rest-text)
    (loop for i in books
       when (string-match "\\[.*\\] *" i)
       collect (concat (propertize (match-string 0 i)
                                   'face 'helm-pinboard-tag-face)
                       (propertize (substring i (match-end 0))
                                   'face 'helm-pinboard-bookmarks-face
                                   'help-echo (helm-c-pinboard-bookmarks-get-value i))))))

;;;###autoload
(defun helm-pinboard ()
  "Start helm-pinboard outside of main helm"
  (interactive)
  (setq helm-source-is-pinboard t)
  (let ((rem-pattern (if helm-pinboard-last-pattern
                         helm-pinboard-last-pattern)))
    (helm 'helm-c-source-pinboard-tv
              rem-pattern nil nil nil "*Helm Pinboard*")))

(provide 'helm-pinboard)


;; (magit-push)
;; (yaoddmuse-post "EmacsWiki" "helm-pinboard.el" (buffer-name) (buffer-string) "update")

;;; helm-pinboard.el ends here
