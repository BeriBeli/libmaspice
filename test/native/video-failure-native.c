#include <VideoToolbox/VideoToolbox.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
void video_failure_classify(uint8_t,uint8_t,int32_t,int32_t[3]);
int main(void){
    const int32_t statuses[]={0,kCMFormatDescriptionError_AllocationFailed,-1,
        kVTVideoDecoderUnsupportedDataFormatErr,kVTFormatDescriptionChangeNotSupportedErr,
        kVTCouldNotFindVideoDecoderErr,kVTCouldNotCreateInstanceErr,kVTVideoDecoderMalfunctionErr,
        kVTVideoDecoderNotAvailableNowErr,kVTVideoDecoderAuthorizationErr,kVTVideoDecoderRemovedErr,
        kVTSessionMalfunctionErr,kVTVideoDecoderNeedsRosettaErr};
    unsigned count=0;
    for(uint8_t codec=0;codec<2;codec++)for(uint8_t stage=0;stage<7;stage++)for(unsigned i=0;i<sizeof(statuses)/sizeof(*statuses);i++){
        int32_t status=statuses[i],reason=0,present=1;
        if(stage==4){reason=1;present=0;}
        else if(stage==3)reason=1;
        else if(stage==0){if(status&&status!=kCMFormatDescriptionError_AllocationFailed)reason=2;}
        else if(stage==1||stage==5){
            switch(status){
                case kVTVideoDecoderUnsupportedDataFormatErr:case kVTFormatDescriptionChangeNotSupportedErr:reason=2;break;
                case kVTCouldNotFindVideoDecoderErr:case kVTCouldNotCreateInstanceErr:case kVTVideoDecoderMalfunctionErr:
                case kVTVideoDecoderNotAvailableNowErr:case kVTVideoDecoderAuthorizationErr:case kVTVideoDecoderRemovedErr:
                case kVTSessionMalfunctionErr:case kVTVideoDecoderNeedsRosettaErr:reason=1;break;
                default:break;
            }
        }
        int32_t out[3];video_failure_classify(codec,stage,status,out);
        assert(out[0]==reason&&out[1]==(reason?present:0)&&out[2]==(reason&&present?status:0));count++;
    }
    printf("%u video failure classifications match named CoreMedia/VideoToolbox SDK constants\n",count);return 0;
}
