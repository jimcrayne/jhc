# Jhc Haskell Compiler

To initialize a fresh clone of the source repository, you must first run:```autoreconf --install```

[How to install](http://repetae.net/computer/jhc/building.shtml)

[The Manual](http://repetae.net/computer/jhc/manual.html)

jhc is a haskell compiler which aims to produce the most efficient programs
possible via whole program analysis and other optimizations. It is reputed to
produce much smaller binaries than other haskell compilers, which is useful if
you are trying to keep down the binary size of your trusted computing base.

NOTE: Jhc presently requires an old version (0.9.X) of the bytestring library.
Due to this, you'll have an easier time at present compiling it with ghc-7.6.X
than with ghc-7.8.X or greater. But it should still be possible, if you have a
newer bytestring package installed, try using ghc-pkg to hide it and expose an
older one.

# Using Jhc

See the [Installation Page](http://repetae.net/computer/jhc/building.shtml) for information about downloading and installing jhc.

For information on running jhc, see [The User's Manual](http://repetae.net/computer/jhc/manual.html).

Join the [jhc mailing list](http://www.haskell.org/mailman/listinfo/jhc) for jhc discussion, announcements, and bug reports.

There is a [spot on the wiki](http://haskell.org/haskellwiki/Jhc) but it doesn't have much info yet. feel free to expand it.

# Developing Jhc

The [development page](http://repetae.net/computer/jhc/development.shtml) has information on how to pull the development tree from the darcs repository

The [bug tracker](http://repetae.net/computer/jhc/bug) tracks known jhc issues, bugs can be added by submitting darcs patches or just posting to the mailing list jhc@haskell.org. NOTE: [Issues on this github mirror](https://github.com/jimcrayne/jhc/issues) will also be forwarded to the mailing list when I get around to it (or when I get around to setting up automatic forwarding).

An informal graph of the internal code motion in jhc is [here](http://repetae.net/computer/jhc/big-picture.pdf).

# Cross-compiling

If you already have a c cross compiling tool chain, then Jhc is set up to cross
compile right out of the box, no compile configuration necessary. But you will need
to create a file $HOME/.jhc/targets.ini which tells jhc which c compiler to use.

The parser for targets.ini is very simple, comments are presently not allowed. Here is an example

	[armhf]
	cc=arm-linux-gnueabihf-gcc-4.9

	[armel]
	cc=arm-linux-gnueabi-gcc-4.9

	[win32]
	cc=i386-mingw32-gcc
	cflags+=-mwindows -mno-cygwin
	executable_extension=.exe
	merge=i686

Using the above file, you can then use the -m switch to specify the backend compiler:

	jhc -marmhf HelloWorld.hs -o hello	

## Website

[Here](http://repetae.net/computer/jhc/) is the original website, belonging to John Meacham.
