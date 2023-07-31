ARCH=$(shell uname -m)

build:
	xcodebuild \
		-workspace RadioPlayer.xcodeproj/project.xcworkspace \
		-scheme RadioPlayer \
		-arch $(ARCH) \
		-configuration release

install:
	-mkdir ./inst
	xcodebuild \
		-workspace RadioPlayer.xcodeproj/project.xcworkspace \
		-scheme RadioPlayer \
		-arch $(ARCH) \
		-configuration release \
		install DSTROOT=./inst

dest:
	xcodebuild \
		-workspace RadioPlayer.xcodeproj/project.xcworkspace \
		-scheme RadioPlayer \
		-arch $(ARCH) \
		-configuration release \
		-showdestinations

clean:
	-rm -rf ./inst
