//===-- File.h --------------------------------------------------*- C++ -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef liblldb_File_h_
#define liblldb_File_h_

#include "lldb/Host/PosixApi.h"
#include "lldb/Utility/IOObject.h"
#include "lldb/Utility/Status.h"
#include "lldb/lldb-private.h"
#include "llvm/ADT/BitmaskEnum.h"

#include <mutex>
#include <stdarg.h>
#include <stdio.h>
#include <sys/types.h>

namespace lldb_private {

LLVM_ENABLE_BITMASK_ENUMS_IN_NAMESPACE();

/// \class File File.h "lldb/Host/File.h"
/// An abstract base class for files.
///
/// Files will often be NativeFiles, which provides a wrapper
/// around host OS file functionality.   But it
/// is also possible to subclass file to provide objects that have file
/// or stream functionality but are not backed by any host OS file.
class File : public IOObject {
public:
  static int kInvalidDescriptor;
  static FILE *kInvalidStream;

  // NB this enum is used in the lldb platform gdb-remote packet
  // vFile:open: and existing values cannot be modified.
  //
  // FIXME
  // These values do not match the values used by GDB
  // * https://sourceware.org/gdb/onlinedocs/gdb/Open-Flags.html#Open-Flags
  // * rdar://problem/46788934
  enum OpenOptions : uint32_t {
    eOpenOptionRead = (1u << 0),  // Open file for reading
    eOpenOptionWrite = (1u << 1), // Open file for writing
    eOpenOptionAppend =
        (1u << 2), // Don't truncate file when opening, append to end of file
    eOpenOptionTruncate = (1u << 3),    // Truncate file when opening
    eOpenOptionNonBlocking = (1u << 4), // File reads
    eOpenOptionCanCreate = (1u << 5),   // Create file if doesn't already exist
    eOpenOptionCanCreateNewOnly =
        (1u << 6), // Can create file only if it doesn't already exist
    eOpenOptionDontFollowSymlinks = (1u << 7),
    eOpenOptionCloseOnExec =
        (1u << 8), // Close the file when executing a new process
    LLVM_MARK_AS_BITMASK_ENUM(/* largest_value= */ eOpenOptionCloseOnExec)
  };

  static mode_t ConvertOpenOptionsForPOSIXOpen(OpenOptions open_options);
  static llvm::Expected<OpenOptions> GetOptionsFromMode(llvm::StringRef mode);
  static bool DescriptorIsValid(int descriptor) { return descriptor >= 0; };

  File()
      : IOObject(eFDTypeFile), m_is_interactive(eLazyBoolCalculate),
        m_is_real_terminal(eLazyBoolCalculate),
        m_supports_colors(eLazyBoolCalculate){};

  /// Read bytes from a file from the current file position into buf.
  ///
  /// NOTE: This function is NOT thread safe. Use the read function
  /// that takes an "off_t &offset" to ensure correct operation in multi-
  /// threaded environments.
  ///
  /// \param[out] buf
  ///
  /// \param[in,out] num_bytes.
  ///    Pass in the size of buf.  Read will pass out the number
  ///    of bytes read.   Zero bytes read with no error indicates
  ///    EOF.
  ///
  /// \return
  ///    success, ENOTSUP, or another error.
  Status Read(void *buf, size_t &num_bytes) override;

  /// Write bytes from buf to a file at the current file position.
  ///
  /// NOTE: This function is NOT thread safe. Use the write function
  /// that takes an "off_t &offset" to ensure correct operation in multi-
  /// threaded environments.
  ///
  /// \param[in] buf
  ///
  /// \param[in,out] num_bytes
  ///    Pass in the size of buf.  Write will pass out the number
  ///    of bytes written.   Write will attempt write the full number
  ///    of bytes and will not return early except on error.
  ///
  /// \return
  ///    success, ENOTSUP, or another error.
  Status Write(const void *buf, size_t &num_bytes) override;

  /// IsValid
  ///
  /// \return
  ///    true iff the file is valid.
  bool IsValid() const override;

  /// Flush any buffers and release any resources owned by the file.
  /// After Close() the file will be invalid.
  ///
  /// \return
  ///     success or an error.
  Status Close() override;

  /// Get a handle that can be used for OS polling interfaces, such
  /// as WaitForMultipleObjects, select, or epoll.   This may return
  /// IOObject::kInvalidHandleValue if none is available.   This will
  /// generally be the same as the file descriptor, this function
  /// is not interchangeable with GetDescriptor().   A WaitableHandle
  /// must only be used for polling, not actual I/O.
  ///
  /// \return
  ///     a valid handle or IOObject::kInvalidHandleValue
  WaitableHandle GetWaitableHandle() override;

  /// Get the file specification for this file, if possible.
  ///
  /// \param[out] file_spec
  ///     the file specification.
  /// \return
  ///     ENOTSUP, success, or another error.
  virtual Status GetFileSpec(FileSpec &file_spec) const;

  /// DEPRECATED! Extract the underlying FILE* and reset this File without closing it.
  ///
  /// This is only here to support legacy SB interfaces that need to convert scripting
  /// language objects into FILE* streams.   That conversion is inherently sketchy and
  /// doing so may cause the stream to be leaked.
  ///
  /// After calling this the File will be reset to its original state.  It will be
  /// invalid and it will not hold on to any resources.
  ///
  /// \return
  ///     The underlying FILE* stream from this File, if one exists and can be extracted,
  ///     nullptr otherwise.
  virtual FILE *TakeStreamAndClear();

  /// Get underlying OS file descriptor for this file, or kInvalidDescriptor.
  /// If the descriptor is valid, then it may be used directly for I/O
  /// However, the File may also perform it's own buffering, so avoid using
  /// this if it is not necessary, or use Flush() appropriately.
  ///
  /// \return
  ///    a valid file descriptor for this file or kInvalidDescriptor
  virtual int GetDescriptor() const;

  /// Get the underlying libc stream for this file, or NULL.
  ///
  /// Not all valid files will have a FILE* stream.   This should only be
  /// used if absolutely necessary, such as to interact with 3rd party
  /// libraries that need FILE* streams.
  ///
  /// \return
  ///    a valid stream or NULL;
  virtual FILE *GetStream();

  /// Seek to an offset relative to the beginning of the file.
  ///
  /// NOTE: This function is NOT thread safe, other threads that
  /// access this object might also change the current file position. For
  /// thread safe reads and writes see the following functions: @see
  /// File::Read (void *, size_t, off_t &) \see File::Write (const void *,
  /// size_t, off_t &)
  ///
  /// \param[in] offset
  ///     The offset to seek to within the file relative to the
  ///     beginning of the file.
  ///
  /// \param[in] error_ptr
  ///     A pointer to a lldb_private::Status object that will be
  ///     filled in if non-nullptr.
  ///
  /// \return
  ///     The resulting seek offset, or -1 on error.
  virtual off_t SeekFromStart(off_t offset, Status *error_ptr = nullptr);

  /// Seek to an offset relative to the current file position.
  ///
  /// NOTE: This function is NOT thread safe, other threads that
  /// access this object might also change the current file position. For
  /// thread safe reads and writes see the following functions: @see
  /// File::Read (void *, size_t, off_t &) \see File::Write (const void *,
  /// size_t, off_t &)
  ///
  /// \param[in] offset
  ///     The offset to seek to within the file relative to the
  ///     current file position.
  ///
  /// \param[in] error_ptr
  ///     A pointer to a lldb_private::Status object that will be
  ///     filled in if non-nullptr.
  ///
  /// \return
  ///     The resulting seek offset, or -1 on error.
  virtual off_t SeekFromCurrent(off_t offset, Status *error_ptr = nullptr);

  /// Seek to an offset relative to the end of the file.
  ///
  /// NOTE: This function is NOT thread safe, other threads that
  /// access this object might also change the current file position. For
  /// thread safe reads and writes see the following functions: @see
  /// File::Read (void *, size_t, off_t &) \see File::Write (const void *,
  /// size_t, off_t &)
  ///
  /// \param[in,out] offset
  ///     The offset to seek to within the file relative to the
  ///     end of the file which gets filled in with the resulting
  ///     absolute file offset.
  ///
  /// \param[in] error_ptr
  ///     A pointer to a lldb_private::Status object that will be
  ///     filled in if non-nullptr.
  ///
  /// \return
  ///     The resulting seek offset, or -1 on error.
  virtual off_t SeekFromEnd(off_t offset, Status *error_ptr = nullptr);

  /// Read bytes from a file from the specified file offset.
  ///
  /// NOTE: This function is thread safe in that clients manager their
  /// own file position markers and reads on other threads won't mess up the
  /// current read.
  ///
  /// \param[in] dst
  ///     A buffer where to put the bytes that are read.
  ///
  /// \param[in,out] num_bytes
  ///     The number of bytes to read form the current file position
  ///     which gets modified with the number of bytes that were read.
  ///
  /// \param[in,out] offset
  ///     The offset within the file from which to read \a num_bytes
  ///     bytes. This offset gets incremented by the number of bytes
  ///     that were read.
  ///
  /// \return
  ///     An error object that indicates success or the reason for
  ///     failure.
  virtual Status Read(void *dst, size_t &num_bytes, off_t &offset);

  /// Write bytes to a file at the specified file offset.
  ///
  /// NOTE: This function is thread safe in that clients manager their
  /// own file position markers, though clients will need to implement their
  /// own locking externally to avoid multiple people writing to the file at
  /// the same time.
  ///
  /// \param[in] src
  ///     A buffer containing the bytes to write.
  ///
  /// \param[in,out] num_bytes
  ///     The number of bytes to write to the file at offset \a offset.
  ///     \a num_bytes gets modified with the number of bytes that
  ///     were read.
  ///
  /// \param[in,out] offset
  ///     The offset within the file at which to write \a num_bytes
  ///     bytes. This offset gets incremented by the number of bytes
  ///     that were written.
  ///
  /// \return
  ///     An error object that indicates success or the reason for
  ///     failure.
  virtual Status Write(const void *src, size_t &num_bytes, off_t &offset);

  /// Flush the current stream
  ///
  /// \return
  ///     An error object that indicates success or the reason for
  ///     failure.
  virtual Status Flush();

  /// Sync to disk.
  ///
  /// \return
  ///     An error object that indicates success or the reason for
  ///     failure.
  virtual Status Sync();

  /// Output printf formatted output to the stream.
  ///
  /// NOTE: this is not virtual, because it just calls the va_list
  /// version of the function.
  ///
  /// Print some formatted output to the stream.
  ///
  /// \param[in] format
  ///     A printf style format string.
  ///
  /// \param[in] ...
  ///     Variable arguments that are needed for the printf style
  ///     format string \a format.
  size_t Printf(const char *format, ...) __attribute__((format(printf, 2, 3)));

  /// Output printf formatted output to the stream.
  ///
  /// Print some formatted output to the stream.
  ///
  /// \param[in] format
  ///     A printf style format string.
  ///
  /// \param[in] args
  ///     Variable arguments that are needed for the printf style
  ///     format string \a format.
  virtual size_t PrintfVarArg(const char *format, va_list args);

  /// Get the permissions for a this file.
  ///
  /// \return
  ///     Bits logical OR'ed together from the permission bits defined
  ///     in lldb_private::File::Permissions.
  uint32_t GetPermissions(Status &error) const;

  /// Return true if this file is interactive.
  ///
  /// \return
  ///     True if this file is a terminal (tty or pty), false
  ///     otherwise.
  bool GetIsInteractive();

  /// Return true if this file from a real terminal.
  ///
  /// Just knowing a file is a interactive isn't enough, we also need to know
  /// if the terminal has a width and height so we can do cursor movement and
  /// other terminal manipulations by sending escape sequences.
  ///
  /// \return
  ///     True if this file is a terminal (tty, not a pty) that has
  ///     a non-zero width and height, false otherwise.
  bool GetIsRealTerminal();

  /// Return true if this file is a terminal which supports colors.
  ///
  /// \return
  ///    True iff this is a terminal and it supports colors.
  bool GetIsTerminalWithColors();

  operator bool() const { return IsValid(); };

  bool operator!() const { return !IsValid(); };

protected:
  LazyBool m_is_interactive;
  LazyBool m_is_real_terminal;
  LazyBool m_supports_colors;

  void CalculateInteractiveAndTerminal();

private:
  DISALLOW_COPY_AND_ASSIGN(File);
};

class NativeFile : public File {
public:
  NativeFile()
      : m_descriptor(kInvalidDescriptor), m_own_descriptor(false),
        m_stream(kInvalidStream), m_options(), m_own_stream(false) {}

  NativeFile(FILE *fh, bool transfer_ownership)
      : m_descriptor(kInvalidDescriptor), m_own_descriptor(false), m_stream(fh),
        m_options(), m_own_stream(transfer_ownership) {}

  NativeFile(int fd, OpenOptions options, bool transfer_ownership)
      : m_descriptor(fd), m_own_descriptor(transfer_ownership),
        m_stream(kInvalidStream), m_options(options), m_own_stream(false) {}

  ~NativeFile() override { Close(); }

  bool IsValid() const override {
    return DescriptorIsValid() || StreamIsValid();
  }

  Status Read(void *buf, size_t &num_bytes) override;
  Status Write(const void *buf, size_t &num_bytes) override;
  Status Close() override;
  WaitableHandle GetWaitableHandle() override;
  Status GetFileSpec(FileSpec &file_spec) const override;
  FILE *TakeStreamAndClear() override;
  int GetDescriptor() const override;
  FILE *GetStream() override;
  off_t SeekFromStart(off_t offset, Status *error_ptr = nullptr) override;
  off_t SeekFromCurrent(off_t offset, Status *error_ptr = nullptr) override;
  off_t SeekFromEnd(off_t offset, Status *error_ptr = nullptr) override;
  Status Read(void *dst, size_t &num_bytes, off_t &offset) override;
  Status Write(const void *src, size_t &num_bytes, off_t &offset) override;
  Status Flush() override;
  Status Sync() override;
  size_t PrintfVarArg(const char *format, va_list args) override;

protected:
  bool DescriptorIsValid() const {
    return File::DescriptorIsValid(m_descriptor);
  }
  bool StreamIsValid() const { return m_stream != kInvalidStream; }

  // Member variables
  int m_descriptor;
  bool m_own_descriptor;
  FILE *m_stream;
  OpenOptions m_options;
  bool m_own_stream;
  std::mutex offset_access_mutex;

private:
  DISALLOW_COPY_AND_ASSIGN(NativeFile);
};

} // namespace lldb_private

#endif // liblldb_File_h_
