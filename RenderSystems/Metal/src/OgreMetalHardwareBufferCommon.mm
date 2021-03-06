/*
-----------------------------------------------------------------------------
This source file is part of OGRE
    (Object-oriented Graphics Rendering Engine)
For the latest info, see http://www.ogre3d.org/

Copyright (c) 2000-2014 Torus Knot Software Ltd

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
-----------------------------------------------------------------------------
*/

#include "OgreMetalHardwareBufferCommon.h"
#include "OgreMetalDevice.h"
#include "OgreDefaultHardwareBufferManager.h"

#import <Metal/MTLDevice.h>
#import <Metal/MTLBlitCommandEncoder.h>

namespace Ogre
{
    MetalHardwareBufferCommon::MetalHardwareBufferCommon( size_t sizeBytes, Usage usage, bool useShadowBuffer,
                                                          uint16 alignment,
                                                          MetalDevice *device ) :
        HardwareBuffer(usage, false, false),
        mBuffer( 0 ),
        mDevice( device ),
        mLastFrameUsed( 0 ),
        mLastFrameGpuWrote( 0 )
    {
        mSizeInBytes = sizeBytes;
        // FIXME read write hazards not handled due to the following commented out
        mLastFrameUsed = 0;//mVaoManager->getFrameCount() - mVaoManager->getDynamicBufferMultiplier();
        mLastFrameGpuWrote = mLastFrameUsed;

        MTLResourceOptions resourceOptions = 0;

        // FIXME always using shared storage for now. Using staging buffers leaks severly
        if( usage & HBU_DETAIL_WRITE_ONLY & 0)
        {
            resourceOptions |= MTLResourceStorageModePrivate;
            resourceOptions |= MTLResourceCPUCacheModeWriteCombined;
        }
        else
        {
            resourceOptions |= MTLResourceStorageModeShared;
        }

        mBuffer = [mDevice->mDevice newBufferWithLength:alignToNextMultiple( sizeBytes, 4u )
                                                    options:resourceOptions];

        if (useShadowBuffer)
        {
            mShadowBuffer.reset(new DefaultHardwareBuffer(mSizeInBytes));
        }
    }
    //-----------------------------------------------------------------------------------
    MetalHardwareBufferCommon::~MetalHardwareBufferCommon()
    {
        mBuffer = 0;
    }
    //-----------------------------------------------------------------------------------
    void MetalHardwareBufferCommon::_notifyDeviceStalled(void)
    {
        mLastFrameUsed      = 0;//mVaoManager->getFrameCount() - mVaoManager->getDynamicBufferMultiplier();
        mLastFrameGpuWrote  = mLastFrameUsed;
    }
    //-----------------------------------------------------------------------------------
    id<MTLBuffer> MetalHardwareBufferCommon::getBufferName( size_t &outOffset )
    {
        mLastFrameUsed = 0;//mVaoManager->getFrameCount();
        outOffset = 0;
        return mBuffer;
    }
    //-----------------------------------------------------------------------------------
    void* MetalHardwareBufferCommon::lockImpl( size_t offset, size_t length, LockOptions options)
    {
        void *retPtr = 0;

        const uint32 currentFrame       = 2;//mVaoManager->getFrameCount();
        const uint32 bufferMultiplier   = 1;//mVaoManager->getDynamicBufferMultiplier();

        {
            if( mBuffer.storageMode != MTLStorageModePrivate )
            {
                if( options == HardwareBuffer::HBL_READ_ONLY )
                {
                    if( currentFrame - mLastFrameGpuWrote < bufferMultiplier )
                        mDevice->stall();
                }
                else if( options != HardwareBuffer::HBL_NO_OVERWRITE )
                {
                    if( currentFrame - mLastFrameUsed < bufferMultiplier )
                    {
                        LogManager::getSingleton().logMessage(
                                    "PERFORMANCE WARNING: locking to a non-HBU_WRITE_ONLY or "
                                    "non-HBU_DISCARDABLE for other than reading is slow/stalling." );

                        mDevice->stall();
                    }
                }

                retPtr = [mBuffer contents];
                retPtr = static_cast<void*>( static_cast<uint8*>( retPtr ) + offset );
            }
            else
            {
                //If we're here, the buffer was created with HBU_WRITE_ONLY, but not discardable.
                //Write to a staging buffer to avoid blocking. We don't have to care about
                //reading access.
                assert( (options != HardwareBuffer::HBL_NORMAL ||
                        options != HardwareBuffer::HBL_READ_ONLY) &&
                        "Reading from a write-only buffer! Create "
                        "the buffer without HBL_WRITE_ONLY bit (or use readData)" );
            }
        }

        return retPtr;
    }
    //-----------------------------------------------------------------------------------
    void MetalHardwareBufferCommon::unlockImpl()
    {
    }
    //-----------------------------------------------------------------------------------
    void MetalHardwareBufferCommon::readData( size_t offset, size_t length, void* pDest )
    {
        assert( (offset + length) <= mSizeInBytes );

        if (mShadowBuffer)
        {
            mShadowBuffer->readData(offset, length, pDest);
            return;
        }

        void const *srcData = 0;
        StagingBuffer *stagingBuffer = 0;

        const uint32 currentFrame       = 0;//mVaoManager->getFrameCount();
        const uint32 bufferMultiplier   = 1;//mVaoManager->getDynamicBufferMultiplier();

        {
            if( mBuffer.storageMode != MTLStorageModePrivate )
            {
                if( currentFrame - mLastFrameGpuWrote < bufferMultiplier )
                    mDevice->stall();
                srcData = [mBuffer contents];
            }
        }

        srcData = static_cast<const void*>( static_cast<const uint8*>( srcData ) + offset );

        memcpy( pDest, srcData, length );
    }
    //-----------------------------------------------------------------------------------
    void MetalHardwareBufferCommon::writeData(size_t offset, size_t length, const void* pSource,
                                              bool discardWholeBuffer)
    {
        discardWholeBuffer = discardWholeBuffer || (offset == 0 && length == mSizeInBytes);
        if (mShadowBuffer)
        {
            mShadowBuffer->writeData(offset, length, pSource, discardWholeBuffer);
        }

        writeDataImpl(offset, length, pSource, discardWholeBuffer);
    }
    void MetalHardwareBufferCommon::writeDataImpl(size_t offset, size_t length, const void* pSource,
                                                  bool discardWholeBuffer)
    {
        // FIXME
        if(true || mBuffer.storageMode == MTLStorageModePrivate)
        {
            //Fast path is through locking (it either discards or already uses a StagingBuffer).
            void *dstData = this->lockImpl( offset, length, HBL_DISCARD);
            memcpy( dstData, pSource, length );
            this->unlockImpl();
        }
    }
    //-----------------------------------------------------------------------------------
    void MetalHardwareBufferCommon::copyData( HardwareBuffer& _srcBuffer, size_t srcOffset,
                                              size_t dstOffset, size_t length, bool discardWholeBuffer )
    {
        if (mShadowBuffer)
        {
            mShadowBuffer->copyData(_srcBuffer, srcOffset, dstOffset, length, discardWholeBuffer);
        }

        auto srcBuffer = static_cast<MetalHardwareBufferCommon*>(&_srcBuffer);
        discardWholeBuffer = discardWholeBuffer || (dstOffset == 0 && length == mSizeInBytes);

        if( srcBuffer->mBuffer.storageMode == MTLStorageModePrivate )
        {
            size_t srcOffsetStart = 0;
            __unsafe_unretained id<MTLBuffer> srcBuf = srcBuffer->getBufferName( srcOffsetStart );
            __unsafe_unretained id<MTLBuffer> dstBuf = mBuffer;

            __unsafe_unretained id<MTLBlitCommandEncoder> blitEncoder = mDevice->getBlitEncoder();
            [blitEncoder copyFromBuffer:srcBuf
                           sourceOffset:srcOffset + srcOffsetStart
                               toBuffer:dstBuf
                      destinationOffset:dstOffset
                                   size:length];
        }
        else
        {
            HardwareBuffer::LockOptions dstOption;
            if( discardWholeBuffer )
                dstOption = HardwareBuffer::HBL_DISCARD;
            else
                dstOption = HardwareBuffer::HBL_WRITE_ONLY;

            const void *srcData = srcBuffer->lockImpl( srcOffset, length, HBL_READ_ONLY);
            void *dstData = this->lockImpl( dstOffset, length, dstOption );

            memcpy( dstData, srcData, length );

            this->unlockImpl();
            srcBuffer->unlockImpl();
        }
    }

    //-----------------------------------------------------------------------------------
    void MetalHardwareBufferCommon::_updateFromShadow(void)
    {
        if( mShadowBuffer && mShadowUpdated && !mSuppressHardwareUpdate )
        {
            HardwareBufferLockGuard shadowLock(mShadowBuffer.get(), mLockStart, mLockSize, HBL_READ_ONLY);
            writeDataImpl(mLockStart, mLockSize, shadowLock.pData, false);
            mShadowUpdated = false;
        }
    }
}
