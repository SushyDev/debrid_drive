defmodule VFS.FileMode do
  @moduledoc """
  Helper module for Unix file mode bitwise operations.
  Handles file types and permissions.
  """

  import Bitwise

  # File type constants
  # bit mask for the file type bit field
  @s_ifmt 0o170000
  # socket
  @s_ifsock 0o140000
  # symbolic link
  @s_iflnk 0o120000
  # regular file
  @s_ifreg 0o100000
  # block device
  @s_ifblk 0o060000
  # directory
  @s_ifdir 0o040000
  # character device
  @s_ifchr 0o020000
  # FIFO
  @s_ififo 0o010000

  # Permission constants
  # set UID bit
  @s_isuid 0o004000
  # set-group-ID bit (see below)
  @s_isgid 0o002000
  # sticky bit (see below)
  @s_isvtx 0o001000
  # owner has read, write, and execute permission
  @s_irwxu 0o000700
  # owner has read permission
  @s_irusr 0o000400
  # owner has write permission
  @s_iwusr 0o000200
  # owner has execute permission
  @s_ixusr 0o000100
  # group has read, write, and execute permission
  @s_irwxg 0o000070
  # group has read permission
  @s_irgrp 0o000040
  # group has write permission
  @s_iwgrp 0o000020
  # group has execute permission
  @s_ixgrp 0o000010
  # others have read, write, and execute permission
  @s_irwxo 0o000007
  # others have read permission
  @s_iroth 0o000004
  # others have write permission
  @s_iwoth 0o000002
  # others have execute permission
  @s_ixoth 0o000001

  # File type constants (public)
  def s_ifmt, do: @s_ifmt
  def s_ifsock, do: @s_ifsock
  def s_iflnk, do: @s_iflnk
  def s_ifreg, do: @s_ifreg
  def s_ifblk, do: @s_ifblk
  def s_ifdir, do: @s_ifdir
  def s_ifchr, do: @s_ifchr
  def s_ififo, do: @s_ififo

  # Permission constants (public)
  def s_isuid, do: @s_isuid
  def s_isgid, do: @s_isgid
  def s_isvtx, do: @s_isvtx
  def s_irwxu, do: @s_irwxu
  def s_irusr, do: @s_irusr
  def s_iwusr, do: @s_iwusr
  def s_ixusr, do: @s_ixusr
  def s_irwxg, do: @s_irwxg
  def s_irgrp, do: @s_irgrp
  def s_iwgrp, do: @s_iwgrp
  def s_ixgrp, do: @s_ixgrp
  def s_irwxo, do: @s_irwxo
  def s_iroth, do: @s_iroth
  def s_iwoth, do: @s_iwoth
  def s_ixoth, do: @s_ixoth

  @doc """
  Checks if a mode represents a directory.
  """
  def dir?(mode) when is_integer(mode) do
    (mode &&& @s_ifmt) == @s_ifdir
  end

  @doc """
  Checks if a mode represents a regular file.
  """
  def regular?(mode) when is_integer(mode) do
    (mode &&& @s_ifmt) == @s_ifreg
  end

  @doc """
  Checks if a mode represents a symbolic link.
  """
  def symlink?(mode) when is_integer(mode) do
    (mode &&& @s_ifmt) == @s_iflnk
  end

  @doc """
  Creates a mode for a directory with the given permissions.
  Default permissions: 0o755
  """
  def directory_mode(permissions \\ 0o755) do
    @s_ifdir ||| permissions
  end

  @doc """
  Creates a mode for a regular file with the given permissions.
  Default permissions: 0o644
  """
  def file_mode(permissions \\ 0o644) do
    @s_ifreg ||| permissions
  end

  @doc """
  Creates a mode for a symbolic link with the given permissions.
  Default permissions: 0o777
  """
  def symlink_mode(permissions \\ 0o777) do
    @s_iflnk ||| permissions
  end

  @doc """
  Extracts the file type from a mode.
  """
  def file_type(mode) when is_integer(mode) do
    mode &&& @s_ifmt
  end

  @doc """
  Extracts the permissions from a mode.
  """
  def permissions(mode) when is_integer(mode) do
    mode &&& 0o777
  end
end
